#!/bin/bash
set -u

export REMOTE_SSH_CONFIGURED=0
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

start_sshd() {
    if [ -z "${SSH_USER:-}" ] && [ -z "${SSH_PASSWORD:-}" ]; then
        log "未设置 SSH_USER/SSH_PASSWORD，跳过 Browser-rendered SSH。"
        return 0
    fi

    if [ -z "${SSH_USER:-}" ] || [ -z "${SSH_PASSWORD:-}" ]; then
        log "错误：启用 SSH 需要同时设置 SSH_USER 和 SSH_PASSWORD。"
        return 1
    fi

    export SSH_PORT="${SSH_PORT:-2222}"
    if ! valid_port "$SSH_PORT"; then
        log "错误：SSH_PORT 必须是 1-65535 的整数。"
        return 1
    fi

    local health_port="${HEALTH_PORT:-7860}"
    local api_port="${API_SERVER_PORT:-8642}"
    local dashboard_port="${HERMES_DASHBOARD_PORT:-9119}"
    if [ "$SSH_PORT" = "$health_port" ]; then
        log "错误：SSH_PORT 不能与 HEALTH_PORT (${health_port}) 相同。"
        return 1
    fi
    if is_true "${API_SERVER_ENABLED:-false}" && [ "$SSH_PORT" = "$api_port" ]; then
        log "错误：SSH_PORT 不能与 Hermes Gateway API 端口 (${api_port}) 相同。"
        return 1
    fi
    if is_true "${HERMES_DASHBOARD:-0}" && [ "$SSH_PORT" = "$dashboard_port" ]; then
        log "错误：SSH_PORT 不能与 Dashboard 端口 (${dashboard_port}) 相同。"
        return 1
    fi

    if printf '%s' "$SSH_USER" | grep -q '[:[:space:]/]'; then
        log "错误：SSH_USER 不能包含冒号、空白或斜杠。"
        return 1
    fi
    if [ "$SSH_USER" = "root" ]; then
        log "错误：SSH_USER 不能为 root；本镜像明确禁用 root SSH。"
        return 1
    fi
    case "$SSH_USER" in
        -*) log "错误：SSH_USER 不能以连字符开头。"; return 1 ;;
    esac

    case "$SSH_PASSWORD" in
        *$'\n'*|*$'\r'*)
            log "错误：SSH_PASSWORD 不能包含换行符。"
            return 1
            ;;
    esac

    if ! id "$SSH_USER" >/dev/null 2>&1; then
        useradd --badname --create-home --shell /bin/bash "$SSH_USER"
        log "已创建 SSH 用户：$SSH_USER"
    fi

    printf '%s:%s\n' "$SSH_USER" "$SSH_PASSWORD" | chpasswd

    if is_true "${SSH_SUDO:-1}"; then
        usermod -aG sudo "$SSH_USER"
        log "已授予 $SSH_USER sudo 权限（sudo 时仍需 SSH_PASSWORD）。"
    fi

    mkdir -p /run/sshd
    cat /remote-access/sshd_config > /tmp/hermes_sshd_config
    printf 'Port %s\n' "$SSH_PORT" >> /tmp/hermes_sshd_config
    printf 'ListenAddress 127.0.0.1\n' >> /tmp/hermes_sshd_config
    printf 'AllowUsers %s\n' "$SSH_USER" >> /tmp/hermes_sshd_config

    # Host key 不烘焙进镜像，在每个新实例启动时生成。
    ssh-keygen -A >/dev/null 2>&1
    if ! /usr/sbin/sshd -t -f /tmp/hermes_sshd_config; then
        log "错误：sshd 配置校验失败。"
        return 1
    fi

    export REMOTE_SSH_CONFIGURED=1

    (
        unset SSH_PASSWORD CF_TUNNEL_TOKEN TUNNEL_TOKEN API_SERVER_KEY || true
        while true; do
            log "启动 sshd：127.0.0.1:${SSH_PORT}"
            /usr/sbin/sshd -D -e -f /tmp/hermes_sshd_config
            rc=$?
            log "sshd 退出 (code=$rc)，5 秒后重启。"
            sleep 5
        done
    ) >>/tmp/sshd.log 2>&1 &
}

start_cloudflared() {
    if [ -z "${CF_TUNNEL_TOKEN:-}" ]; then
        log "未设置 CF_TUNNEL_TOKEN，跳过 Cloudflare Tunnel。"
        return 0
    fi

    case "${CF_TUNNEL_PROTOCOL:-auto}" in
        auto|quic|http2) ;;
        *) log "错误：CF_TUNNEL_PROTOCOL 仅支持 auto、quic、http2。"; return 1 ;;
    esac

    case "${CF_TUNNEL_LOGLEVEL:-info}" in
        debug|info|warn|error|fatal) ;;
        *) log "错误：CF_TUNNEL_LOGLEVEL 仅支持 debug、info、warn、error、fatal。"; return 1 ;;
    esac

    export REMOTE_CF_TUNNEL_CONFIGURED=1

    (
        # cloudflared 仅保留自己需要的 TUNNEL_TOKEN；不继承 SSH 密码。
        export TUNNEL_TOKEN="$CF_TUNNEL_TOKEN"
        unset CF_TUNNEL_TOKEN SSH_PASSWORD API_SERVER_KEY || true
        while true; do
            log "启动 cloudflared（protocol=${CF_TUNNEL_PROTOCOL:-auto}）。"
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

if ! start_sshd; then
    log "SSH 初始化失败。"
    return 1 2>/dev/null || exit 1
fi
if ! start_cloudflared; then
    log "Cloudflare Tunnel 初始化失败。"
    return 1 2>/dev/null || exit 1
fi

log "远程访问初始化完成。日志：/tmp/sshd.log、/tmp/cloudflared.log"
