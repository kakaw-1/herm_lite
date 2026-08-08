#!/bin/bash

# 本文件通过 source 加载。
#
# 不要在这里使用 set -e / set -u，
# 避免改变父级 entrypoint.sh 的行为。


# ============================================================
# Logging
# ============================================================

log_local() {

    printf '[local-services] %s\n' "$*"

}


# ============================================================
# Boolean helper
# ============================================================

is_true() {

    case "${1:-}" in

        1|true|TRUE|yes|YES|on|ON)

            return 0
            ;;

        *)

            return 1
            ;;

    esac

}


# ============================================================
# Port validation
# ============================================================

valid_port() {

    case "${1:-}" in

        ''|*[!0-9]*)

            return 1
            ;;

    esac


    [ "$1" -ge 1 ] \
        && [ "$1" -le 65535 ]

}


# ============================================================
# Hermes Dashboard
# ============================================================

start_dashboard() {


    # --------------------------------------------------------
    # Dashboard 默认关闭
    # --------------------------------------------------------

    if ! is_true "${HERMES_DASHBOARD:-0}"; then

        log_local "HERMES_DASHBOARD 未启用，跳过 Dashboard。"

        return 0

    fi


    # --------------------------------------------------------
    # Dashboard 绑定
    # --------------------------------------------------------

    export HERMES_DASHBOARD_HOST="127.0.0.1"


    # 如果环境变量设置：
    #
    # HERMES_DASHBOARD_PORT=9110
    #
    # 则这里使用 9110。
    #
    # 没设置才使用默认 9119。
    export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"


    # --------------------------------------------------------
    # 端口检查
    # --------------------------------------------------------

    if ! valid_port "$HERMES_DASHBOARD_PORT"; then

        log_local "错误：HERMES_DASHBOARD_PORT 必须是 1-65535 的整数。"

        return 1

    fi


    # --------------------------------------------------------
    # 避免和 Health 抢端口
    # --------------------------------------------------------

    if [ "$HERMES_DASHBOARD_PORT" = "${HEALTH_PORT:-7860}" ]; then

        log_local "错误：Dashboard 端口不能与 HEALTH_PORT 相同。"

        return 1

    fi


    # --------------------------------------------------------
    # Dashboard 后台运行
    # --------------------------------------------------------
    #
    # 这里仍然保留 Dashboard 自身的自动重启。
    #
    # 这个和 Gateway 无关。
    #
    # 如果你连 Dashboard 也不想自动重启，
    # 可以再把这里的 while true 移除。
    # --------------------------------------------------------

    (

        while true; do


            log_local \
                "启动 Hermes Dashboard：http://127.0.0.1:${HERMES_DASHBOARD_PORT}"


            if hermes dashboard \
                --host 0.0.0.0 \
                --port "$HERMES_DASHBOARD_PORT" \
                --no-open \
                --skip-build \
                --insecure
            then

                rc=0

            else

                rc=$?

            fi


            log_local \
                "Hermes Dashboard 退出 (code=$rc)，5 秒后重启。"


            sleep 5

        done

    ) >>/tmp/hermes-dashboard.log 2>&1 &


    return 0
}


# ============================================================
# Startup
# ============================================================
#
# health_server.py 不在这里启动。
#
# Health 由 /entrypoint.sh 单独启动。
# ============================================================

if ! start_dashboard; then

    return 1 2>/dev/null || exit 1

fi


log_local \
    "本地服务初始化完成。Dashboard 日志：/tmp/hermes-dashboard.log"
