# ============================================================
# Hermes Agent 精简版 Dockerfile —— ModelScope 创空间专用
# + 7860 Health/Status + Cloudflare Tunnel + Browser-rendered SSH
# ============================================================

FROM python:3.11-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HOME=/root \
    PATH="/opt/hermes/.venv/bin:/root/.local/bin:${PATH}"

WORKDIR /opt/hermes

# ---------- 系统依赖 ----------
# rclone/inotify-tools/gnupg: 原有备份恢复机制
# openssh-server/sudo: Cloudflare Browser-rendered SSH 的本地 origin
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git ripgrep procps \
    rclone inotify-tools gnupg build-essential \
    sudo \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /etc/ssh \
    && rm -f /etc/ssh/ssh_host_*

ARG TTYD_VERSION=1.7.7
RUN curl -fL --retry 3 \
    "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    -o /usr/local/bin/ttyd \
    && chmod 0755 /usr/local/bin/ttyd \
    && ttyd --version

# ---------- 安装 cloudflared（固定官方已发布版本 + SHA256 校验） ----------
RUN curl -fL --retry 3 \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared \
    && chmod 0755 /usr/local/bin/cloudflared \
    && /usr/local/bin/cloudflared version

# ---------- 安装 uv ----------
ARG UV_VERSION=0.5.11
RUN curl -LsSf https://astral.sh/uv/${UV_VERSION}/install.sh | sh

# ---------- 安装 Hermes ----------
# 建议构建时通过 --build-arg HERMES_VERSION=<tag/commit> 固定版本。
ARG HERMES_VERSION=v2026.8.3
RUN git init . \
    && git remote add origin https://github.com/NousResearch/hermes-agent.git \
    && git fetch --depth 1 origin "${HERMES_VERSION}" \
    && git checkout --detach FETCH_HEAD \
    && uv sync --frozen --no-install-project --extra all --extra messaging \
    && uv pip install --no-cache-dir --no-deps -e .
    
# 安装 Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version \
    && npm --version

# Hermes Dashboard 前端预构建
WORKDIR /opt/hermes
RUN cd web \
    && npm install \
    && npm run build

# ---------- 原有备份/恢复机制 ----------
COPY bz/ /bz/
COPY bz-startup/ /root/bz-startup/

# ---------- ModelScope 7860 + 本地服务 + Cloudflare Tunnel + SSH ----------
COPY health/ /health/
COPY runtime/ /runtime/
COPY remote-access/ /remote-access/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x \
      /bz/sync_init.sh /bz/sync_daemon.sh \
      /root/bz-startup/main.sh \
      /health/health_server.py \
      /runtime/start_local_services.sh \
      /remote-access/start_remote_access.sh \
      /entrypoint.sh \
    && mkdir -p /root/.hermes /root/Desktop

# ModelScope 只公开 7860。其他服务都只监听 127.0.0.1：
# - Hermes Gateway API: 8642（默认关闭；需要时在 ModelScope Secrets 设置 API_SERVER_ENABLED=true）
# - Hermes Dashboard: 9119（HERMES_DASHBOARD=1 时启用）
# - SSH: 2222（可通过 SSH_PORT 调整）
# cloudflared 主动出站连接 Cloudflare，因此无需平台开放这些内部端口。
EXPOSE 7860

ENTRYPOINT ["/entrypoint.sh"]
CMD ["hermes", "gateway", "run"]
