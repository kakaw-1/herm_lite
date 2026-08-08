#!/bin/bash


set -e

export HOME="${HOME:-/root}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# ============================================================
# 基础网络绑定
# ============================================================

# ModelScope 对外健康检查 / 状态页
export HEALTH_HOST="0.0.0.0"
export HEALTH_PORT="${HEALTH_PORT:-7860}"

# Hermes Gateway API
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-false}"
export API_SERVER_HOST="127.0.0.1"
export API_SERVER_PORT="${API_SERVER_PORT:-8642}"

# Hermes Dashboard
export HERMES_DASHBOARD_HOST="127.0.0.1"
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"

# Web Shell
export WEB_SHELL_PORT="${WEB_SHELL_PORT:-2222}"

# 本项目保留原 /root/.hermes 持久化语义，
# 因此 Gateway 仍以 root 运行。
export HERMES_ALLOW_ROOT_GATEWAY="${HERMES_ALLOW_ROOT_GATEWAY:-1}"

# Gateway 异常退出后的重新拉起间隔。
export GATEWAY_RESTART_DELAY="${GATEWAY_RESTART_DELAY:-2}"

case "$GATEWAY_RESTART_DELAY" in
    ''|*[!0-9]*)
        echo "错误：GATEWAY_RESTART_DELAY 必须是非负整数。"
        exit 1
        ;;
esac


# ============================================================
# 1) 恢复 Hermes 数据，并启动实时备份
# ============================================================

if [ "${SKIP_RESTORE:-}" = "1" ]; then
    echo "检测到 SKIP_RESTORE=1，跳过 Hermes 配置恢复与自动备份"
else
    echo "开始 Hermes 历史配置恢复，并启动实时备份守护..."

    if /bz/sync_init.sh; then
        nohup /bz/sync_daemon.sh \
            >/tmp/hermes-sync.log \
            2>&1 &
    else
        echo "提示：恢复机制不可用，继续启动 Hermes（不会启动同步守护）。"
    fi
fi


# ============================================================
# 2) 用户自定义初始化脚本
# ============================================================

if [ -x /root/bz-startup/main.sh ]; then
    /root/bz-startup/main.sh
fi




source /remote-access/start_remote_access.sh

unset \
    WEB_SHELL_PASSWORD \
    WEB_SHELL_HTTP_PASSWORD \
    CF_TUNNEL_TOKEN \
    TUNNEL_TOKEN \
    || true



case "$API_SERVER_ENABLED" in
    1|true|TRUE|yes|YES|on|ON)

        if [ -z "${API_SERVER_KEY:-}" ]; then

            API_SERVER_KEY="$(
                python - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
            )"

            export API_SERVER_KEY

            echo \
                "Hermes Gateway API 已启用在 127.0.0.1:${API_SERVER_PORT}；" \
                "未提供 API_SERVER_KEY，已生成本实例临时 key。"
        fi
        ;;
esac




source /runtime/start_local_services.sh



gateway_supervisor() {

    local gateway_pid=""
    local sleep_pid=""
    local rc=0


    # --------------------------------------------------------
    # supervisor 自己收到 TERM / INT
    # --------------------------------------------------------

    stop_gateway_supervisor() {

        # 避免重复进入 trap
        trap - TERM INT


        # 如果当前正在等待 restart delay，
        # 先结束 sleep。
        if [ -n "$sleep_pid" ] \
            && kill -0 "$sleep_pid" 2>/dev/null
        then
            kill -TERM "$sleep_pid" 2>/dev/null || true
        fi


        # 如果 Gateway 正在运行，
        # 给 Gateway 转发 SIGTERM。
        if [ -n "$gateway_pid" ] \
            && kill -0 "$gateway_pid" 2>/dev/null
        then

            echo \
                "[gateway-supervisor] 收到停止信号，" \
                "正在停止 Gateway (pid=$gateway_pid)..."

            kill -TERM "$gateway_pid" 2>/dev/null || true

            wait "$gateway_pid" 2>/dev/null || true
        fi


        exit 0
    }


    trap stop_gateway_supervisor TERM INT


    # --------------------------------------------------------
    # Gateway 永久监管循环
    # --------------------------------------------------------

    while true; do

        echo "[gateway-supervisor] 启动 Gateway..."

        "$@" \
            > >(tee -a /tmp/hermes-gateway.log) \
            2>&1 &

        gateway_pid=$!


        echo \
            "[gateway-supervisor] Gateway pid=$gateway_pid"


        # ----------------------------------------------------
        # 等待当前 Gateway
        # ----------------------------------------------------

        if wait "$gateway_pid"; then
            rc=0
        else
            rc=$?
        fi


        gateway_pid=""


        echo \
            "[gateway-supervisor] Gateway 已退出 " \
            "(code=$rc)，${GATEWAY_RESTART_DELAY} 秒后重新启动。"


        # ----------------------------------------------------
        # restart delay
        # ----------------------------------------------------
        #
        # sleep 也放后台，
        # 这样 supervisor 收到 TERM 时可以立刻打断。
        # ----------------------------------------------------

        sleep "$GATEWAY_RESTART_DELAY" &
        sleep_pid=$!

        wait "$sleep_pid" 2>/dev/null || true

        sleep_pid=""

    done
}


# ============================================================
# 启动 Gateway Supervisor
# ============================================================

gateway_supervisor "$@" &

GATEWAY_SUPERVISOR_PID=$!


echo \
    "[entrypoint] Gateway supervisor pid=$GATEWAY_SUPERVISOR_PID"


echo \
    "[entrypoint] 启动 ModelScope 状态页：" \
    "http://0.0.0.0:${HEALTH_PORT}"


env \
    -u API_SERVER_KEY \
    -u SSH_PASSWORD \
    -u CF_TUNNEL_TOKEN \
    -u TUNNEL_TOKEN \
    python /health/health_server.py \
    > >(tee -a /tmp/hermes-health.log) \
    2>&1 &

HEALTH_PID=$!


echo \
    "[entrypoint] Health pid=$HEALTH_PID"



shutdown() {

    local signal="${1:-TERM}"


    # 防止 shutdown 期间再次进入 trap
    trap - TERM INT


    echo \
        "[entrypoint] 收到 ${signal}，" \
        "正在停止 Health 与 Gateway supervisor..."


    # --------------------------------------------------------
    # 停 Gateway supervisor
    # --------------------------------------------------------

    if kill -0 \
        "$GATEWAY_SUPERVISOR_PID" \
        2>/dev/null
    then

        kill -TERM \
            "$GATEWAY_SUPERVISOR_PID" \
            2>/dev/null \
            || true
    fi


    # --------------------------------------------------------
    # 停 Health
    # --------------------------------------------------------

    if kill -0 \
        "$HEALTH_PID" \
        2>/dev/null
    then

        kill -TERM \
            "$HEALTH_PID" \
            2>/dev/null \
            || true
    fi


    # --------------------------------------------------------
    # 等待子进程退出
    # --------------------------------------------------------

    wait \
        "$GATEWAY_SUPERVISOR_PID" \
        2>/dev/null \
        || true

    wait \
        "$HEALTH_PID" \
        2>/dev/null \
        || true


    echo \
        "[entrypoint] 所有主服务已停止。"


    exit 0
}


trap 'shutdown TERM' TERM
trap 'shutdown INT' INT



if wait "$HEALTH_PID"; then
    HEALTH_RC=0
else
    HEALTH_RC=$?
fi


echo \
    "[entrypoint] Health server 已退出 " \
    "(code=$HEALTH_RC)，" \
    "停止 Gateway supervisor 并结束容器。"


if kill -0 \
    "$GATEWAY_SUPERVISOR_PID" \
    2>/dev/null
then

    kill -TERM \
        "$GATEWAY_SUPERVISOR_PID" \
        2>/dev/null \
        || true
fi


wait \
    "$GATEWAY_SUPERVISOR_PID" \
    2>/dev/null \
    || true


exit "$HEALTH_RC"
