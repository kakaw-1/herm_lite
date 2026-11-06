#!/bin/bash
# 用户自定义启动脚本（每次开机无条件执行，必须幂等）。
#
# 注意（v0.23.0）：
#   entrypoint 以 /opt/hermes/.venv/bin 优先的 PATH 运行本脚本，但上游镜像
#   的 venv 是 sealed（只读、不含 pip），装包一律走 `hermes pm install`，
#   它会写入 $HERMES_HOME/installs 下的依赖世代，不再写 venv。
#   旧的 `uv pip install --python <venv>` 在 sealed venv 上会失败。
#
# 本脚本只做"必须早于 Hermes 启动"的轻量工作：
#   * 飞书网关依赖自愈（首启/重建后补装 feishu extra）
#   * 可选后台服务的自愈拉起（脚本不存在就静默跳过）
# 其余工具（camoufox 等）统一由 cron 任务在 Hermes 启动后调用
# ~/.hermes/scripts/tool-install.sh 安装，避免阻塞启动。

STARTUP_LOG=/tmp/bz-startup.log

VENV_PY=/opt/hermes/.venv/bin/python

# --- 飞书机器人网关依赖 自愈安装 ---
# v0.23.0 镜像预装 [all] + messaging，不含 feishu extra
# （pyproject: feishu = ["lark-oapi==1.7.5", "qrcode==7.4.2"]）。
# 这里同步补装一次（首次 1-3 分钟，之后 import 命中秒过），
# gateway 自己的 lazy-install 也会兜底，所以失败不阻塞启动。
{
  echo "===== $(date '+%F %T') bz-startup: 飞书依赖检查 ====="
  if ! "$VENV_PY" -c "import lark_oapi, websockets, qrcode" 2>/dev/null; then
    echo "[$(date '+%T')] 缺少飞书依赖，执行 hermes pm install --extra feishu ..."
    if timeout 300 hermes pm install --extra feishu; then
      echo "[$(date '+%T')] feishu extra 安装完成"
    else
      echo "[$(date '+%T')] WARN: feishu extra 安装失败/超时，交由 gateway lazy-install 重试"
    fi
  else
    echo "[$(date '+%T')] 飞书依赖已就绪，跳过"
  fi
  echo "===== $(date '+%F %T') 完成 ====="
} >> "$STARTUP_LOG" 2>&1

# --- Resin 代理池后台自愈（opencode2api 已于 2026-10-29 移除，仅剩 Resin）---
# 不阻塞启动：丢后台跑，wrapper 内部会等 ~/.hermes 同步到 watchdog 脚本后再拉起。
# 幂等（进程在就静默退出）；cron 任务 45bc75465420 每 5 分钟兜底。
RESIN_BOOT=/root/.hermes/scripts/resin_boot.sh
if [ -f "$RESIN_BOOT" ]; then
  setsid nohup bash "$RESIN_BOOT" >/dev/null 2>&1 < /dev/null &
else
  echo "[$(date '+%T')] resin_boot.sh 尚未同步到位（正常，cron watchdog 会兜底）" >> "$STARTUP_LOG" 2>&1
fi

# --- 备份链目录占位（部分脚本假定这些路径存在）---
for d in /root/.openclaw /root/.codex /root/.claude; do mkdir -p "$d"; done
[ -f /root/.zsh_history ] || touch /root/.zsh_history

exit 0
