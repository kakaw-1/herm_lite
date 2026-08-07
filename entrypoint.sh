#!/bin/bash
# Hermes Lite entrypoint - ModelScope health + persistence + Cloudflare remote access
set -e

export HOME="${HOME:-/root}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# 固定平台与内部服务的安全绑定关系。
export HEALTH_HOST="0.0.0.0"
export HEALTH_PORT="${HEALTH_PORT:-7860}"
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-false}"
export API_SERVER_HOST="127.0.0.1"
export API_SERVER_PORT="${API_SERVER_PORT:-8642}"
export HERMES_DASHBOARD_HOST="127.0.0.1"
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
export WEB_SHELL_PORT="${WEB_SHELL_PORT:-2222}"
# 本项目保留原 /root/.hermes 持久化语义，因此 Gateway 仍以 root 运行。
export HERMES_ALLOW_ROOT_GATEWAY="${HERMES_ALLOW_ROOT_GATEWAY:-1}"

# 1) 先恢复 Hermes 数据，再启动备份守护。
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

# 2) 用户自定义初始化脚本。
if [ -x /root/bz-startup/main.sh ]; then
    /root/bz-startup/main.sh
fi

# 3) 先启动 loopback sshd + cloudflared，让这两个子进程只拿到自己需要的远程访问凭证。
source /remote-access/start_remote_access.sh

# 远程访问子进程已经拿到最小化环境副本；从后续 Dashboard / Health / Hermes 环境移除远程凭证。
unset \
    WEB_SHELL_PASSWORD \
    WEB_SHELL_HTTP_PASSWORD \
    CF_TUNNEL_TOKEN \
    TUNNEL_TOKEN \
    || true

# 4) Hermes Gateway API 默认关闭（API_SERVER_ENABLED 默认 false）。
#    若用户显式开启且未给固定 key，则生成一次性随机 key。
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

# 5) 启动 7860 状态页与可选的本地 Dashboard。
source /runtime/start_local_services.sh

# 6) Hermes 保持 PID 1，确保平台停止容器时信号直接传递给主程序。
exec "$@"
