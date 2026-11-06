#!/bin/bash
# Hermes Lite entrypoint
# Gateway 只在容器启动时启动一次，不做自动重启。

set -e

export HOME="${HOME:-/root}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# ============================================================
# 基础配置
# ============================================================

# ModelScope Health / 状态页
export HEALTH_HOST="0.0.0.0"
export HEALTH_PORT="${HEALTH_PORT:-7860}"

# Hermes Gateway API
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-false}"
export API_SERVER_HOST="127.0.0.1"
export API_SERVER_PORT="${API_SERVER_PORT:-8642}"

# Hermes Dashboard
# 环境变量设置 HERMES_DASHBOARD_PORT=9110 时会直接使用 9110。
export HERMES_DASHBOARD_HOST="127.0.0.1"
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"

# Web Shell
export WEB_SHELL_PORT="${WEB_SHELL_PORT:-2222}"

# 允许 root 运行 Gateway
export HERMES_ALLOW_ROOT_GATEWAY="${HERMES_ALLOW_ROOT_GATEWAY:-1}"

# Hermes 数据目录（v0.23.0 起上游默认 /opt/data + UID 10000；
# 本部署继续用 /root/.hermes，root 运行，tar 备份路径保持不变）
export HERMES_HOME="${HERMES_HOME:-/root/.hermes}"


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
# 1b) 镜像升级对齐（v0.23.0）
#
# 上游 Docker 镜像把这三件事放在 docker/stage2-hook.sh 里，但它假定
# HERMES_HOME=/opt/data + UID 10000 + s6 监督树，直接调用会 usermod /
# chown -R 把 /root/.hermes 的属主改成 hermes(10000)。
# 这里只复刻必需的三个动作，跳过 chown / UID 重映射 / 目录 seed：
#
#   a) config schema 迁移（33 -> 52），迁移器自己会先备份到 backups/config/
#   b) PM 依赖世代与 sealed venv 对齐（旧 tar 里的依赖事实不能带进来）
#   c) 内置技能同步（只增/只更新未被用户改过的，不碰自建技能）
#
# 任何一步失败都只记日志 —— 新容器必须能起来。
# ============================================================

HB=/opt/hermes
HB_PY="$HB/.venv/bin/python"

if [ -x "$HB_PY" ]; then

    # --- a) config schema 迁移 ---
    if [ -f "$HERMES_HOME/config.yaml" ]; then

        echo "[entrypoint] config schema 迁移检查..."

        "$HB_PY" "$HB/scripts/docker_config_migrate.py" \
            || echo "[entrypoint] WARN: config 迁移失败，继续启动"

    else

        echo "[entrypoint] 未找到 $HERMES_HOME/config.yaml，跳过 config 迁移。"
    fi

    # --- b) PM 依赖世代对齐 ---
    echo "[entrypoint] PM 依赖世代对齐..."

    "$HB_PY" -c "
from pathlib import Path
from hermes_cli.runtime_state import collect_generations
from pm.environments import install_state_dir
from pm.recovery import refresh_dependencies
from pm.runtime import collect_runtime_generations

root = Path('$HB')

print('[entrypoint] dependency environment:', refresh_dependencies(root))
print(
    '[entrypoint] collected',
    len(
        collect_generations(root)
        + collect_runtime_generations(install_state_dir(root) / 'pm-runtime')
    ),
    'unused dependency generations',
)
" || echo "[entrypoint] WARN: 依赖对齐失败，回落到镜像自带 sealed venv"

    # --- c) 内置技能同步 ---
    if [ -d "$HB/skills" ]; then

        "$HB_PY" "$HB/tools/skills_sync.py" \
            || echo "[entrypoint] WARN: skills_sync 失败，继续启动"
    fi

else

    echo "[entrypoint] WARN: 未找到 $HB_PY，跳过镜像对齐步骤。"
fi


# ============================================================
# 2) 用户自定义初始化
# ============================================================

if [ -x /root/bz-startup/main.sh ]; then
    /root/bz-startup/main.sh
fi


# ============================================================
# 3) 远程访问
# ============================================================

source /remote-access/start_remote_access.sh


# 远程访问相关进程已经拿到所需变量，
# 后续不再传递这些敏感环境变量。
unset \
    WEB_SHELL_PASSWORD \
    WEB_SHELL_HTTP_PASSWORD \
    CF_TUNNEL_TOKEN \
    TUNNEL_TOKEN \
    || true


# ============================================================
# 4) Hermes Gateway API
# ============================================================

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

            echo "Hermes Gateway API 已启用在 127.0.0.1:${API_SERVER_PORT}；未提供 API_SERVER_KEY，已生成本实例临时 key。"

        fi

        ;;

esac


# ============================================================
# 5) 可选本地服务
# ============================================================
#
# 这里只启动 Dashboard。
# Health 已经不再由 start_local_services.sh 启动。
# ============================================================

source /runtime/start_local_services.sh


# ============================================================
# 6) 启动 Gateway
# ============================================================
#
# 注意：
#
# Gateway 只启动这一次。
#
# 如果之后：
#
#   - Gateway 崩溃
#   - Gateway 被 kill
#   - Gateway 手动停止
#
# entrypoint 不会重新执行 hermes gateway run。
#
# ============================================================

echo "[entrypoint] 启动 Hermes Gateway（仅启动一次，不自动拉起）..."


"$@" \
    > >(tee -a /tmp/hermes-gateway.log) \
    2>&1 &


GATEWAY_PID=$!


echo "[entrypoint] Gateway pid=$GATEWAY_PID"


# ============================================================
# 7) 启动 Health
# ============================================================
#
# Health 是容器生命周期锚点。
#
# Gateway 即使退出：
#
#   Health 仍然运行
#   entrypoint 仍然运行
#   容器仍然运行
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
# 8) 容器停止信号处理
# ============================================================
#
# entrypoint.sh 保持 PID 1。
#
# ModelScope / Docker 停止容器时：
#
#   SIGTERM
#      ├── Gateway（如果还活着）
#      └── Health
#
# ============================================================

shutdown() {

    local signal="${1:-TERM}"


    # 防止重复触发
    trap - TERM INT


    echo "[entrypoint] 收到 ${signal}，正在停止 Health 与 Gateway..."


    # --------------------------------------------------------
    # 停止 Gateway
    # --------------------------------------------------------

    if kill -0 "$GATEWAY_PID" 2>/dev/null; then

        echo "[entrypoint] 停止 Gateway (pid=$GATEWAY_PID)..."

        kill -TERM \
            "$GATEWAY_PID" \
            2>/dev/null \
            || true

    fi


    # --------------------------------------------------------
    # 停止 Health
    # --------------------------------------------------------

    if kill -0 "$HEALTH_PID" 2>/dev/null; then

        echo "[entrypoint] 停止 Health (pid=$HEALTH_PID)..."

        kill -TERM \
            "$HEALTH_PID" \
            2>/dev/null \
            || true

    fi


    # --------------------------------------------------------
    # 等待进程退出
    # --------------------------------------------------------

    wait \
        "$GATEWAY_PID" \
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
# 9) Health 决定容器生命周期
# ============================================================
#
# 这里只等待 Health。
#
# 不等待 Gateway。
#
# 所以：
#
# Gateway exit
#     ↓
# 不重启 Gateway
#     ↓
# Health 仍然运行
#     ↓
# entrypoint 仍然运行
#     ↓
# 容器保持运行
#
#
# 只有 Health 退出：
#
# Health exit
#     ↓
# 停止仍存活的 Gateway
#     ↓
# entrypoint 退出
#     ↓
# 容器退出
#
# ============================================================

if wait "$HEALTH_PID"; then

    HEALTH_RC=0

else

    HEALTH_RC=$?

fi


echo "[entrypoint] Health server 已退出 (code=$HEALTH_RC)，准备结束容器。"


# ============================================================
# Health 退出后清理 Gateway
# ============================================================

if kill -0 "$GATEWAY_PID" 2>/dev/null; then

    echo "[entrypoint] Health 已退出，停止 Gateway (pid=$GATEWAY_PID)..."

    kill -TERM \
        "$GATEWAY_PID" \
        2>/dev/null \
        || true

fi


wait \
    "$GATEWAY_PID" \
    2>/dev/null \
    || true


exit "$HEALTH_RC"
