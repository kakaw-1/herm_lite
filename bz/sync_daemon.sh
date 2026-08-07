#!/bin/bash

if [ ! -d "/mnt/workspace" ] && [ -z "${S3_BUCKET}" ] && [ -z "${WEBDAV_URL}" ]; then
    exit 1
fi

echo "启动 Hermes 配置实时备份服务"
echo "本地实时备份 -> /mnt/workspace/root（文件变化时）；远程快照 -> 每天北京时间 05:00 定时执行一次（S3 优先，否则 WebDAV）"

REMOTE_BACKUP_HOUR=5

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

# 前台主循环：专职监听文件变化，实时全量同步到 /mnt/workspace
while true; do
    inotifywait -r -e modify,create,delete,move --fromfile "/bz/watch.txt" --exclude '(^|/)(\.git|\.venv|venv)(/|$)'
    if [ -d "/mnt/workspace" ]; then
        sleep 6
        rclone sync /root/ /mnt/workspace/root/ \
            --filter-from /bz/rules.txt --delete-excluded \
            --create-empty-src-dirs --links --ignore-errors --metadata
    fi
done
