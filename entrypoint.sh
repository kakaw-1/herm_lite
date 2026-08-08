#!/bin/bash
# Hermes Lite entrypoint - ModelScope health + persistence + Cloudflare remote access

set -e

export HOME="${HOME:-/root}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# ============================================================
# 基础配置
# ============================================================

# ModelScope 对外健康检查 / 状态页
export HEALTH_HOST="0.0.0.0"
export HEALTH_PORT="${HEALTH_PORT:-7860}"

# Hermes Gateway API
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-false}"
export API_SERVER_HOST="127.0.0.1"
export API_SERVER_PORT="${API_SERVER_PORT:-8642}"

# Hermes Dashboard
# 如果环境变量设置了 HERMES_DASHBOARD_PORT=9110，这里会使用 9110；
# 未设置时才使用默认值 9119。
export HERMES_DASHBOARD_HOST="127.0.0.1"
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"

# Web Shell
export WEB_SHELL_PORT="${WEB_SHELL_PORT:-2222}"

# 本项目保留 /root/.hermes 持久化语义，因此 Gateway 仍以 root 运行。
export HERMES_ALLOW_ROOT_GATEWAY="${HERMES_ALLOW_ROOT_GATEWAY:-1}"

# Gateway 退出后的自动拉起间隔（秒）
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
        nohup /bz/sync_daemon.sh >/tmp/hermes-sync.log 2>&1 &
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


# ============================================================
# 3) 启动远程访问
# ============================================================

source /remote-access/start_remote_access.sh

# 远程访问子进程已经拿到需要的环境变量；
# 从后续 Health / Dashboard / Hermes 环境中移除凭证。
unset \
    WEB_SHELL_PASSWORD \
    WEB_SHELL_HTTP_PASSWORD \
    CF_TUNNEL_TOKEN \
    TUNNEL_TOKEN \
    || true


# ============================================================
# 4) Hermes Gateway API 配置
# ============================================================

case "$API_SERVER_ENABLED" in
    1|true|TRUE|yes|YES|on|ON)

        if [ -z "${API_SERVER_KEY:-}" ]; then

            API_SERVER_KEY="$(python - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"

            export API_SERVER_KEY

            echo "Hermes Gateway API 已启用在 127.0.0.1:${API_SERVER_PORT}；未提供 API_SERVER_KEY，已生成本实例临时 key。"
        fi

        ;;
esac


# ============================================================
# 5) 启动可选本地服务
# ============================================================
#
# 注意：
# Health 不再从 start_local_services.sh 启动，
# 这里只负责 Dashboard 等可选本地服务。
# ============================================================

source /runtime/start_local_services.sh


# ============================================================
# 6) Gateway Supervisor
# ============================================================
#
# Gateway 不再是 PID 1。
#
# Gateway：
#   - 正常退出
#   - 崩溃
#   - 被 kill
#
# 都会自动重新拉起。
#
# 因此：
#
# Gateway restart != container restart
#
# ============================================================

gateway_supervisor() {

    local gateway_pid=""
    local delay_pid=""
    local rc=0


    # --------------------------------------------------------
    # supervisor 收到 TERM / INT
    # --------------------------------------------------------

    stop_gateway_supervisor() {

        trap - TERM INT


        # 如果当前正在 restart delay，则结束 sleep
        if [ -n "$delay_pid" ] \
            && kill -0 "$delay_pid" 2>/dev/null
        then
            kill -TERM "$delay_pid" 2>/dev/null || true
        fi


        # 停止当前 Gateway
        if [ -n "$gateway_pid" ] \
            && kill -0 "$gateway_pid" 2>/dev/null
        then

            echo "[gateway-supervisor] 收到停止信号，正在停止 Gateway (pid=$gateway_pid)..."

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


        # Gateway 日志同时：
        # 1. 输出到容器日志
        # 2. 写入 /tmp/hermes-gateway.log
        "$@" \
            > >(tee -a /tmp/hermes-gateway.log) \
            2>&1 &

        gateway_pid=$!


        echo "[gateway-supervisor] Gateway pid=$gateway_pid"


        # ----------------------------------------------------
        # 等待 Gateway 退出
        # ----------------------------------------------------

        if wait "$gateway_pid"; then
            rc=0
        else
            rc=$?
        fi


        gateway_pid=""


        echo "[gateway-supervisor] Gateway 已退出 (code=$rc)，${GATEWAY_RESTART_DELAY} 秒后重新启动。"


        # ----------------------------------------------------
        # restart delay
        # ----------------------------------------------------

        sleep "$GATEWAY_RESTART_DELAY" &
        delay_pid=$!

        wait "$delay_pid" 2>/dev/null || true

        delay_pid=""

    done
}


# ============================================================
# 7) 启动 Gateway Supervisor
# ============================================================

gateway_supervisor "$@" &

GATEWAY_SUPERVISOR_PID=$!


echo "[entrypoint] Gateway supervisor pid=$GATEWAY_SUPERVISOR_PID"


# ============================================================
# 8) 启动 ModelScope Health
# ============================================================
#
# Health 是容器生命周期锚点。
#
# Gateway 重启期间：
#
#   health_server.py 仍然运行
#   :7860 仍然可访问
#   ModelScope 不会因为 Gateway 重启而认为容器死亡
#
# ============================================================

echo "[entrypoint] 启动 ModelScope 状态页：http://0.0.0.0:${HEALTH_PORT}"


env \
    -u API_SERVER_KEY \
    -u SSH_PASSWORD \
    -u CF_TUNNEL_TOKEN \
    -u TUNNEL_TOKEN \
    python /health/health_server.py \
    > >(tee -a /tmp/hermes-health.log) \
    2>&1 &


HEALTH_PID=$!


echo "[entrypoint] Health pid=$HEALTH_PID"


# ============================================================
# 9) PID 1 信号处理
# ============================================================
#
# entrypoint.sh 保持 PID 1。
#
# ModelScope / Docker 停止容器时：
#
# SIGTERM
#    │
#    ├── Gateway supervisor
#    │      └── Gateway
#    │
#    └── Health
#
# ============================================================

shutdown() {

    local signal="${1:-TERM}"


    # 防止重复进入 shutdown
    trap - TERM INT


    echo "[entrypoint] 收到 ${signal}，正在停止 Health 与 Gateway supervisor..."


    # --------------------------------------------------------
    # 停 Gateway supervisor
    # --------------------------------------------------------

    if kill -0 "$GATEWAY_SUPERVISOR_PID" 2>/dev/null; then

        kill -TERM \
            "$GATEWAY_SUPERVISOR_PID" \
            2>/dev/null \
            || true

    fi


    # --------------------------------------------------------
    # 停 Health
    # --------------------------------------------------------

    if kill -0 "$HEALTH_PID" 2>/dev/null; then

        kill -TERM \
            "$HEALTH_PID" \
            2>/dev/null \
            || true

    fi


    # --------------------------------------------------------
    # 等待退出
    # --------------------------------------------------------

    wait \
        "$GATEWAY_SUPERVISOR_PID" \
        2>/dev/null \
        || true


    wait \
        "$HEALTH_PID" \
        2>/dev/null \
        || true


    echo "[entrypoint] 主服务已停止。"


    exit 0
}


trap 'shutdown TERM' TERM
trap 'shutdown INT' INT


# ============================================================
# 10) Health 决定容器生命周期
# ============================================================
#
# 这里故意只 wait Health。
#
# 不 wait Gateway：
# Gateway 的生命周期由 gateway_supervisor 管理。
#
# Gateway 挂掉：
#   → supervisor 重启 Gateway
#   → 容器继续运行
#
# Health 挂掉：
#   → 停 Gateway
#   → entrypoint 退出
#   → 容器退出
#
# ============================================================

if wait "$HEALTH_PID"; then
    HEALTH_RC=0
else
    HEALTH_RC=$?
fi


echo "[entrypoint] Health server 已退出 (code=$HEALTH_RC)，停止 Gateway supervisor 并结束容器。"


# ============================================================
# Health 死亡后停止 Gateway Supervisor
# ============================================================

if kill -0 "$GATEWAY_SUPERVISOR_PID" 2>/dev/null; then

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
