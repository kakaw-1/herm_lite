FROM python:3.11-slim-bookworm


# ============================================================
# 基础环境
# ============================================================

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HOME=/root \
    PATH="/opt/hermes/.venv/bin:/root/.local/bin:${PATH}"

WORKDIR /opt/hermes


# ============================================================
# 系统依赖
# ============================================================


RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        ripgrep \
        procps \
        rclone \
        inotify-tools \
        gnupg \
        build-essential \
        sudo \
    && rm -rf /var/lib/apt/lists/*


# ============================================================
# ttyd Web Shell
# ============================================================

ARG TTYD_VERSION=1.7.7

RUN curl -fL --retry 3 \
    "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
    -o /usr/local/bin/ttyd \
    && chmod 0755 /usr/local/bin/ttyd \
    && ttyd --version


# ============================================================
# SQLite
#
# Hermes 需要：
# - SQLite >= 3.51.3
# - FTS5
# ============================================================

ARG SQLITE_VERSION=3530400

RUN curl -fL --retry 3 \
    "https://www.sqlite.org/2026/sqlite-autoconf-${SQLITE_VERSION}.tar.gz" \
    -o /tmp/sqlite.tar.gz \
    && mkdir -p /tmp/sqlite-src \
    && tar -xzf /tmp/sqlite.tar.gz \
        -C /tmp/sqlite-src \
        --strip-components=1 \
    && cd /tmp/sqlite-src \
    && CPPFLAGS="-DSQLITE_ENABLE_FTS5" \
        ./configure --prefix=/usr/local \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig \
    && rm -rf \
        /tmp/sqlite.tar.gz \
        /tmp/sqlite-src


# 确保 Python 优先加载 /usr/local/lib 下的新 SQLite
ENV LD_LIBRARY_PATH="/usr/local/lib"


# ============================================================
# SQLite 构建验证
# ============================================================

RUN python - <<'PY'
import sqlite3

print("Linked SQLite:", sqlite3.sqlite_version)

version = tuple(
    map(int, sqlite3.sqlite_version.split("."))
)

assert version >= (3, 51, 3), (
    f"SQLite version too old: {sqlite3.sqlite_version}"
)

con = sqlite3.connect(":memory:")

compile_options = {
    row[0]
    for row in con.execute("PRAGMA compile_options")
}

print(
    "FTS5 compile option:",
    "ENABLE_FTS5" in compile_options,
)

assert "ENABLE_FTS5" in compile_options, (
    "SQLite was built without ENABLE_FTS5"
)

con.execute(
    "CREATE VIRTUAL TABLE fts5_test "
    "USING fts5(content)"
)

con.execute(
    "INSERT INTO fts5_test(content) "
    "VALUES ('Hermes SQLite FTS5 test')"
)

result = con.execute(
    "SELECT content "
    "FROM fts5_test "
    "WHERE fts5_test MATCH 'Hermes'"
).fetchone()

assert result is not None

print("SQLite FTS5: OK")
PY


# ============================================================
# cloudflared
# ============================================================
#
# 当前使用 latest。
# 如果以后追求完全可复现构建，建议改成固定版本。
# ============================================================

RUN curl -fL --retry 3 \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
    -o /usr/local/bin/cloudflared \
    && chmod 0755 /usr/local/bin/cloudflared \
    && /usr/local/bin/cloudflared version


# ============================================================
# uv
# ============================================================

ARG UV_VERSION=0.5.11

RUN curl -LsSf \
    "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    | sh


# ============================================================
# Hermes Agent
# ============================================================

ARG HERMES_VERSION=v2026.8.3

RUN git init . \
    && git remote add origin \
        https://github.com/NousResearch/hermes-agent.git \
    && git fetch \
        --depth 1 \
        origin "${HERMES_VERSION}" \
    && git checkout --detach FETCH_HEAD \
    && uv sync \
        --frozen \
        --no-install-project \
        --extra all \
        --extra messaging \
    && uv pip install \
        --no-cache-dir \
        --no-deps \
        -e .


# ============================================================
# Node.js 22
#
# Hermes Dashboard 前端构建需要 Node/npm。
# ============================================================

RUN curl -fsSL \
    https://deb.nodesource.com/setup_22.x \
    | bash - \
    && apt-get update \
    && apt-get install -y \
        --no-install-recommends \
        nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version \
    && npm --version


# ============================================================
# Hermes Dashboard 前端预构建
#
# ============================================================

WORKDIR /opt/hermes

RUN cd web \
    && npm install \
    && npm run build


# ============================================================
# 备份 / 恢复
# ============================================================

COPY bz/ /bz/

# 如果你仍然需要 bz-startup 才保留。
COPY bz-startup/ /root/bz-startup/


# ============================================================
# ModelScope Health + Local Services + Remote Access
# ============================================================

COPY health/ /health/
COPY runtime/ /runtime/
COPY remote-access/ /remote-access/
COPY entrypoint.sh /entrypoint.sh


# ============================================================
# 权限 + Shell 语法检查
#
# 这个非常重要：
# 像刚才 sync_init.sh 那种多一个 "\" 的问题，
# 会直接在 GitHub Actions 构建阶段被发现。
# ============================================================

RUN chmod +x \
        /bz/sync_init.sh \
        /bz/sync_daemon.sh \
        /root/bz-startup/main.sh \
        /health/health_server.py \
        /runtime/start_local_services.sh \
        /remote-access/start_remote_access.sh \
        /entrypoint.sh \
    && bash -n /bz/sync_init.sh \
    && bash -n /bz/sync_daemon.sh \
    && bash -n /root/bz-startup/main.sh \
    && bash -n /runtime/start_local_services.sh \
    && bash -n /remote-access/start_remote_access.sh \
    && bash -n /entrypoint.sh \
    && mkdir -p \
        /root/.hermes \
        /root/Desktop


# ============================================================
# Ports
# ============================================================

EXPOSE 7860


# ============================================================
# Startup
# ============================================================

ENTRYPOINT ["/entrypoint.sh"]

CMD ["hermes", "gateway", "run"]
