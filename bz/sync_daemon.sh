#!/bin/bash
# 实时备份守护（防抖版）—— 替换镜像层 /bz/sync_daemon.sh 的主循环
#
# 旧版问题：inotifywait 每退一次就立刻无条件跑一遍全量 rclone sync /root → ossfs，
# 而 kanban.db-shm / *.log / *.tmp / heartbeat 这类热文件每秒都在抖，
# 导致 rclone 常驻 ~50% CPU、约 5 次/分钟，loadavg 长期 4~6（2 核配额）。
#
# 新版：① 热文件不参与监听；② 事件静默 QUIET 秒后才同步；③ 两次同步至少隔 MIN_GAP 秒；
#       ④ rclone 加 --update 跳过未变更文件的重校验。
# 远端每日快照（05:00 S3/WebDAV）逻辑保持原样。

if [ ! -d "/mnt/workspace" ] && [ -z "${S3_BUCKET}" ] && [ -z "${WEBDAV_URL}" ]; then
    exit 1
fi

echo "启动 Hermes 配置实时备份服务（防抖模式）"
echo "本地实时备份 -> /mnt/workspace/root（静默 ${QUIET:-60}s 后触发，最小间隔 ${MIN_GAP:-300}s）；远程快照 -> 每天北京时间 05:00"

REMOTE_BACKUP_HOUR=5
QUIET="${SYNC_QUIET:-60}"
MIN_GAP="${SYNC_MIN_GAP:-300}"
HOT_RE='(-wal|-shm|\.log|\.tmp|\.rclonelink|\.availability\.json|\.tick\.lock|\.heartbeat|ticker_heartbeat|ticker_last_success|\.swap)$'

# 记录"上次远程备份的北京时间日期"；优先放 /mnt/workspace 以便容器重启后仍能跨天去重
if [ -d "/mnt/workspace" ]; then
    LAST_REMOTE_DATE_FILE="/mnt/workspace/.hermes_last_remote_backup_date"
else
    LAST_REMOTE_DATE_FILE="/tmp/.hermes_last_remote_backup_date"
fi

# 每日远程快照：独立定时进程，什么都不依赖，每 60 秒检查一次，到北京时间 05:00 直接执行（当天未备份过即做）
(
    while true; do
        BJ_DATE=$(date -u -d '+8 hours' '+%F' 2>/dev/null || TZ=Asia/Shanghai date '+%F')
        BJ_HOUR=$((10#$(date -u -d '+8 hours' '+%H' 2>/dev/null || TZ=Asia/Shanghai date '+%H')))
        LAST_REMOTE_DATE=$(cat "$LAST_REMOTE_DATE_FILE" 2>/dev/null || echo "never")
        if [ "${BJ_HOUR}" -ge "${REMOTE_BACKUP_HOUR}" ] && [ "${BJ_DATE}" != "${LAST_REMOTE_DATE}" ]; then
            if [ -n "${S3_BUCKET}" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 执行每日 S3 远程备份..."
                rclone sync /root/ /tmp/root/ \
                    --filter-from /bz/rules.txt --delete-excluded \
                    --create-empty-src-dirs --links --ignore-errors
                if [ -n "${BACKUP_ENC_PASS}" ]; then
                    tar -zcPf - /tmp/root | gpg --batch --yes --passphrase "$BACKUP_ENC_PASS" --symmetric --cipher-algo AES256 -o /tmp/data.tar.gz
                else
                    tar -zcPf /tmp/data.tar.gz /tmp/root
                fi
                rclone copyto /tmp/data.tar.gz ":s3:${S3_BUCKET}/${S3_BACKUP_PATH:-backups/data_hermes.tar.gz}" \
                    --s3-provider Other \
                    --s3-access-key-id "${S3_KEY_ID}" \
                    --s3-secret-access-key "${S3_ACCESS_KEY}" \
                    --s3-endpoint "${S3_ENDPOINT:-https://s3.cstcloud.cn}" \
                    --links --ignore-errors --metadata
            elif [ -n "${WEBDAV_URL}" ]; then
                if [ -z "${WEBDAV_PASSWD_MASK}" ]; then
                    WEBDAV_PASSWD_MASK=$(rclone obscure "${WEBDAV_PASSWD}")
                fi
                echo "$(date '+%Y-%m-%d %H:%M:%S') 执行每日 WebDAV 远程备份..."
                rclone sync /root/ /tmp/root/ \
                    --filter-from /bz/rules.txt --delete-excluded \
                    --create-empty-src-dirs --links --ignore-errors --metadata
                if [ -n "${BACKUP_ENC_PASS}" ]; then
                    tar -zcPf - /tmp/root | gpg --batch --yes --passphrase "$BACKUP_ENC_PASS" --symmetric --cipher-algo AES256 -o /tmp/data.tar.gz
                else
                    tar -zcPf /tmp/data.tar.gz /tmp/root
                fi
                rclone copyto /tmp/data.tar.gz ":webdav:/${WEBDAV_BACKUP_PATH:-backups/data_hermes.tar.gz}" \
                    --webdav-vendor other \
                    --webdav-url "${WEBDAV_URL}" \
                    --webdav-user "${WEBDAV_USER}" \
                    --webdav-pass "${WEBDAV_PASSWD_MASK}" \
                    --header "User-Agent: ${WEBDAV_CLIENT_UA:-Zotero/8.0}" \
                    --links --ignore-errors --metadata
            fi
            echo "${BJ_DATE}" > "$LAST_REMOTE_DATE_FILE"
        fi
        sleep 60
    done
) &
REMOTE_BACKUP_PID=$!
echo "每日远程快照定时进程已启动 (PID $REMOTE_BACKUP_PID)"

do_sync() {
    [ -d "/mnt/workspace" ] || return 0
    local t0=$(date +%s)
    rclone sync /root/ /mnt/workspace/root/ \
        --filter-from /bz/rules.txt --delete-excluded \
        --create-empty-src-dirs --links --ignore-errors --metadata \
        --update --checkers 2 --transfers 2 --timeout 60s --contimeout 15s
    echo "$(date '+%F %T') 同步完成，耗时 $(( $(date +%s) - t0 ))s"
}

# watch.txt 里若出现不存在的目录，inotifywait 会立即返回，旧版据此空转成每 6 秒一次全量 sync。
# 每轮前先补齐目录（幂等）。
recreate_watch_dirs() {
    local d
    while read -r d; do
        case "$d" in ''|'#'*) continue ;; esac
        [ -e "$d" ] || { mkdir -p "$d" 2>/dev/null; }
    done < /bz/watch.txt
}

# 触发同步的变更数量阈值（超过则不再等防抖静默，直接同步，避免长时间活跃永不落盘）
BATCH_TRIGGER="${SYNC_BATCH_TRIGGER:-200}"

LAST_SYNC=0
while true; do
    recreate_watch_dirs
    EVT=$(mktemp /dev/shm/.bz_sync_evt.XXXXXX 2>/dev/null || mktemp /tmp/.bz_sync_evt.XXXXXX)
    KEEP=$(mktemp /dev/shm/.bz_sync_keep.XXXXXX 2>/dev/null || mktemp /tmp/.bz_sync_keep.XXXXXX)
    # inotifywait 的 exclude 组合正则实测会把所有事件一起吞掉（只留建链提示），
    # 因此这里只排除 .git/.venv，热文件在收集后用 grep -v 过滤，行为可验证。
    inotifywait -r -m -q -e modify,create,delete,move \
        --fromfile "/bz/watch.txt" \
        --exclude '(^|/)(\.git|\.venv|venv)(/|$)' \
        > "$EVT" 2>/dev/null &
    IW=$!

    # 等到第一次真实事件（最多 1 小时）；watcher 意外退出则重来
    waited=0
    while [ "$waited" -lt 3600 ]; do
        if [ -s "$EVT" ]; then break; fi
        kill -0 "$IW" 2>/dev/null || break
        sleep 2; waited=$((waited + 2))
    done

    if [ -s "$EVT" ]; then
        # 过滤热文件（WAL/SHM、日志、cron 心跳、临时文件）
        grep -vE "$HOT_RE" "$EVT" > "$KEEP" 2>/dev/null || true
        if [ ! -s "$KEEP" ]; then
            # 本轮全是噪声：不跑 rclone，只清理并继续等
            kill "$IW" 2>/dev/null; wait "$IW" 2>/dev/null
            rm -f "$EVT" "$KEEP"
            sleep 20
            continue
        fi

        # 防抖：事件流静默 $QUIET 秒后才认为一轮改动结束；事件数破阈值则不等待
        last=$(wc -l < "$KEEP" 2>/dev/null || echo 0)
        stable=0
        while [ "$stable" -lt "$QUIET" ]; do
            sleep 2
            grep -vE "$HOT_RE" "$EVT" > "$KEEP" 2>/dev/null || true
            cur=$(wc -l < "$KEEP" 2>/dev/null || echo 0)
            if [ "$cur" -ge "$BATCH_TRIGGER" ]; then break; fi
            if [ "$cur" = "$last" ]; then stable=$((stable + 2)); else stable=0; last=$cur; fi
            kill -0 "$IW" 2>/dev/null || break
        done

        # 最小间隔：避免活跃期里每分钟一次全量比对
        now=$(date +%s)
        if [ $((now - LAST_SYNC)) -lt "$MIN_GAP" ]; then
            sleep $((MIN_GAP - (now - LAST_SYNC)))
        fi
        do_sync
        LAST_SYNC=$(date +%s)
    fi

    # 重启 watcher：换掉不断增长的事件文件，并补齐启动期间可能漏掉的事件窗口
    kill "$IW" 2>/dev/null
    wait "$IW" 2>/dev/null
    rm -f "$EVT" "$KEEP"
    sleep 20
done
