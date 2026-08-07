#!/bin/bash
set -u

log_local() {
    printf '[local-services] %s\n' "$*"
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

start_health_server() {
    export HEALTH_HOST="0.0.0.0"
    export HEALTH_PORT="${HEALTH_PORT:-7860}"
    if ! valid_port "$HEALTH_PORT"; then
        log_local "错误：HEALTH_PORT 必须是 1-65535 的整数。"
        return 1
    fi

    (
        while true; do
            log_local "启动 ModelScope 状态页：http://0.0.0.0:${HEALTH_PORT}"
            env -u API_SERVER_KEY -u SSH_PASSWORD -u CF_TUNNEL_TOKEN -u TUNNEL_TOKEN python /health/health_server.py
            rc=$?
            log_local "health server 退出 (code=$rc)，5 秒后重启。"
            sleep 5
        done
    ) >>/tmp/hermes-health.log 2>&1 &
}

start_dashboard() {
    if ! is_true "${HERMES_DASHBOARD:-0}"; then
        log_local "HERMES_DASHBOARD 未启用，跳过 Dashboard。"
        return 0
    fi

    export HERMES_DASHBOARD_HOST="127.0.0.1"
    export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
    if ! valid_port "$HERMES_DASHBOARD_PORT"; then
        log_local "错误：HERMES_DASHBOARD_PORT 必须是 1-65535 的整数。"
        return 1
    fi
    if [ "$HERMES_DASHBOARD_PORT" = "${HEALTH_PORT:-7860}" ]; then
        log_local "错误：Dashboard 端口不能与 HEALTH_PORT 相同。"
        return 1
    fi

    (
        while true; do
            log_local "启动 Hermes Dashboard：http://127.0.0.1:${HERMES_DASHBOARD_PORT}"
            hermes dashboard \
                --host 0.0.0.0 \
                --port "$HERMES_DASHBOARD_PORT" \
                --no-open \
                --skip-build \
                --insecure
            rc=$?
            log_local "Hermes Dashboard 退出 (code=$rc)，5 秒后重启。"
            sleep 5
        done
    ) >>/tmp/hermes-dashboard.log 2>&1 &
}

start_health_server || return 1 2>/dev/null || exit 1
start_dashboard || return 1 2>/dev/null || exit 1
log_local "本地服务初始化完成。日志：/tmp/hermes-health.log、/tmp/hermes-dashboard.log"
