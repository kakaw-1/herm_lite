#!/bin/bash
set -u

export REMOTE_WEB_SHELL_CONFIGURED=0
export REMOTE_CF_TUNNEL_CONFIGURED=0

log() {
    printf '[remote-access] %s\n' "$*"
}

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

valid_port() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac

    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}


# ============================================================
# Web Shell
# ============================================================

start_web_shell() {

    # 完全未配置时跳过
    if [ -z "${WEB_SHELL_USER:-}" ] \
        && [ -z "${WEB_SHELL_PASSWORD:-}" ]; then

        log "未配置 Web Shell，跳过 ttyd。"
        return 0
    fi

    # 用户名和密码必须同时配置
    if [ -z "${WEB_SHELL_USER:-}" ] \
        || [ -z "${WEB_SHELL_PASSWORD:-}" ]; then

        log "错误：WEB_SHELL_USER 和 WEB_SHELL_PASSWORD 必须同时设置。"
        return 1
    fi

    # 默认继续使用原 SSH 的 2222 端口
    export WEB_SHELL_PORT="${WEB_SHELL_PORT:-2222}"

    if ! valid_port "$WEB_SHELL_PORT"; then
        log "错误：WEB_SHELL_PORT 必须是 1-65535。"
        return 1
    fi

    local health_port="${HEALTH_PORT:-7860}"
    local api_port="${API_SERVER_PORT:-8642}"
    local dashboard_port="${HERMES_DASHBOARD_PORT:-9119}"

    # 防止与健康页冲突
    if [ "$WEB_SHELL_PORT" = "$health_port" ]; then
        log "错误：WEB_SHELL_PORT 与 HEALTH_PORT 冲突。"
        return 1
    fi

    # 防止与 Gateway API 冲突
    if is_true "${API_SERVER_ENABLED:-false}" \
        && [ "$WEB_SHELL_PORT" = "$api_port" ]; then

        log "错误：WEB_SHELL_PORT 与 Gateway API 端口冲突。"
        return 1
    fi

    # 防止与 Dashboard 冲突
    if is_true "${HERMES_DASHBOARD:-0}" \
        && [ "$WEB_SHELL_PORT" = "$dashboard_port" ]; then

        log "错误：WEB_SHELL_PORT 与 Dashboard 端口冲突。"
        return 1
    fi

    # 禁止直接创建 root Web Shell 用户
    if [ "$WEB_SHELL_USER" = "root" ]; then
        log "错误：WEB_SHELL_USER 不能为 root。"
        return 1
    fi

    # 创建 Linux 用户
    if ! id "$WEB_SHELL_USER" >/dev/null 2>&1; then

        useradd \
            --badname \
            --create-home \
            --shell /bin/bash \
            "$WEB_SHELL_USER"

        log "已创建 Web Shell 用户：$WEB_SHELL_USER"
    fi

    # Linux 用户密码与 Web Shell 登录密码相同
    printf '%s:%s\n' \
        "$WEB_SHELL_USER" \
        "$WEB_SHELL_PASSWORD" \
        | chpasswd

    # 默认授予 sudo 权限
    if is_true "${WEB_SHELL_SUDO:-1}"; then

        usermod -aG sudo "$WEB_SHELL_USER"

        log "已授予 $WEB_SHELL_USER sudo 权限（sudo 使用同一个 WEB_SHELL_PASSWORD）。"
    fi

    export REMOTE_WEB_SHELL_CONFIGURED=1

    (
        while true; do

            log "启动 ttyd：127.0.0.1:${WEB_SHELL_PORT}"

            ttyd \
                -W \
                -i 127.0.0.1 \
                -p "$WEB_SHELL_PORT" \
                -c "${WEB_SHELL_USER}:${WEB_SHELL_PASSWORD}" \
                sudo \
                    -u "$WEB_SHELL_USER" \
                    -H \
                    /bin/bash -l

            rc=$?

            log "ttyd 退出 (code=$rc)，5 秒后重启。"

            sleep 5

        done

    ) >>/tmp/ttyd.log 2>&1 &
}


# ============================================================
# Cloudflare Tunnel
# ============================================================

start_cloudflared() {

    if [ -z "${CF_TUNNEL_TOKEN:-}" ]; then

        log "未设置 CF_TUNNEL_TOKEN，跳过 Cloudflare Tunnel。"
        return 0
    fi

    case "${CF_TUNNEL_PROTOCOL:-auto}" in

        auto|quic|http2)
            ;;

        *)
            log "错误：CF_TUNNEL_PROTOCOL 仅支持 auto/quic/http2。"
            return 1
            ;;

    esac

    export REMOTE_CF_TUNNEL_CONFIGURED=1

    (
        # cloudflared 使用自己的 Tunnel Token
        export TUNNEL_TOKEN="$CF_TUNNEL_TOKEN"

        # cloudflared 不需要知道 Web Shell 密码
        unset \
            CF_TUNNEL_TOKEN \
            WEB_SHELL_PASSWORD \
            API_SERVER_KEY \
            || true

        while true; do

            log "启动 cloudflared..."

            cloudflared tunnel \
                --no-autoupdate \
                --protocol "${CF_TUNNEL_PROTOCOL:-auto}" \
                --loglevel "${CF_TUNNEL_LOGLEVEL:-info}" \
                run

            rc=$?

            log "cloudflared 退出 (code=$rc)，5 秒后重连。"

            sleep 5

        done

    ) >>/tmp/cloudflared.log 2>&1 &
}


# ============================================================
# 启动
# ============================================================

if ! start_web_shell; then

    log "Web Shell 初始化失败。"

    return 1 2>/dev/null || exit 1
fi

if ! start_cloudflared; then

    log "Cloudflare Tunnel 初始化失败。"

    return 1 2>/dev/null || exit 1
fi

log "远程访问初始化完成。日志：/tmp/ttyd.log、/tmp/cloudflared.log"
