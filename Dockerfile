# ============================================================
# Hermes Lite — glue layer on top of the official Hermes Agent image
#
# 从 v2026.8.3 升到 v0.23.0 不是版本号变化，而是运行时架构换血：
#   - 上游改用 debian trixie + PM 自管 Python 3.14 + sealed venv
#     + Node 26 + pinned Chromium + 预构建 web_dist / webapp bundle
#   - 47 条依赖里 46 条带 python_version >= '3.14' 标记，3.11 上解析为空
#     => 无法就地升级，只能换基底重建
#
# 本仓库只叠 glue：
#   ttyd / cloudflared / rclone / inotify-tools / sshd / sqlite3-cli / tini
#   数据仍留在 /root/.hermes（不跟随上游 /opt/data + UID 10000 非 root 用户）
#   ENTRYPOINT 覆盖为 /entrypoint.sh，tini 做 PID 1 回收孤儿进程
#   （上游靠 s6-overlay 做这件事，我们不用 s6）
# ============================================================

FROM nousresearch/hermes-agent:v0.23.0


# ============================================================
# 基础环境
# ============================================================

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HOME=/root \
    HERMES_HOME=/root/.hermes \
    HERMES_ALLOW_ROOT_GATEWAY=1 \
    HERMES_DOCKER_EXEC_AS_ROOT=1


# 上游 PATH 把 /opt/hermes/bin 放在最前面 —— 那是 root 降权 shim
# （setuidgid hermes, UID 10000），以 root 运行时会把进程降到 UID 10000，
# 读不了 /root/.hermes（0700）。这里把 venv 的可执行目录提到最前，
# 并移除 /opt/hermes/bin，让 `hermes` 直接解析到 sealed venv 的入口。
ENV PATH="/opt/hermes/.venv/bin:/root/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"

WORKDIR /opt/hermes


# ============================================================
# 系统依赖（glue 层）
#
# 上游镜像已自带：ca-certificates curl git procps xz-utils gcc g++ make
# chromium 运行库、node 26、npm、ffmpeg、ripgrep、python3.14
# 这里只补本部署特有的：备份链(rclone/inotify-tools/gnupg)、远程访问
# (openssh-server)、Web Shell 提权(sudo)、sqlite3 CLI 冷备 state.db
# ============================================================

RUN apt-get -o Acquire::Retries=3 update \
    && apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        ripgrep \
        procps \
        rclone \
        inotify-tools \
        gnupg \
        sudo \
        openssh-server \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*


# ============================================================
# sqlite3 CLI（必须与上游替换后的 libsqlite3 版本一致）
#
# 上游镜像把 /usr/local/lib/libsqlite3.so.0 换成自编的 3.53.4，
# 而 Debian trixie 的 sqlite3 CLI 是 3.46.1 —— 两者 header/library
# 版本不匹配，CLI 直接报 "SQLite header and source version mismatch"
# 并以 1 退出。snap_daily.sh 用 sqlite3 对 state.db 做在线冷备，
# 装发行版 CLI 会让备份链第一天就断。
#
# 这里改用 sqlite.org 官方静态构建的 sqlite-tools（自带库，无外部依赖），
# 版本与上游 lib 对齐到同一个 autoconf 版本号。
# ============================================================

ARG SQLITE_AUTOCONF_VERSION=3530400

RUN curl -fL --retry 3 \
        "https://www.sqlite.org/2026/sqlite-tools-linux-x64-${SQLITE_AUTOCONF_VERSION}.zip" \
        -o /tmp/sqlite-tools.zip \
    && /usr/local/bin/python3 -c "import os, shutil, zipfile; z = zipfile.ZipFile('/tmp/sqlite-tools.zip'); name = next(n for n in z.namelist() if os.path.basename(n) == 'sqlite3'); src = z.open(name); dst = open('/usr/local/bin/sqlite3', 'wb'); shutil.copyfileobj(src, dst); dst.close(); src.close(); print('extracted', name)" \
    && chmod 0755 /usr/local/bin/sqlite3 \
    && rm -f /tmp/sqlite-tools.zip \
    && sqlite3 --version


# ============================================================
# tini —— PID 1 孤儿进程回收
#
# 上游用 s6-overlay 的 /init 做 PID 1；我们用 tini 覆盖 ENTRYPOINT，
# 只保留"回收孤儿进程 + 转发信号"这一项能力。
# 上游在 /usr/bin/tini 放了一个 s6 转发 shim，所以真 tini 放独立路径，
# 避免与 apt 的 tini 包 / 上游 shim 抢同一个文件名。
# ============================================================

ARG TINI_VERSION=v0.19.0

RUN curl -fL --retry 3 \
        "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static" \
        -o /usr/local/bin/tini-real \
    && chmod 0755 /usr/local/bin/tini-real \
    && /usr/local/bin/tini-real --version


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
# cloudflared（quick tunnel / named tunnel）
# ============================================================

RUN curl -fL --retry 3 \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
    -o /usr/local/bin/cloudflared \
    && chmod 0755 /usr/local/bin/cloudflared \
    && /usr/local/bin/cloudflared version


# ============================================================
# uv
#
# 上游镜像的依赖由 PM 自管（pm/lock.json 里的 uv），与这里无关。
# 保留 /root/.local/bin/uv 是为了让既有用户脚本里写死的路径不失效
# （resin_boot.sh 等按 /root/.local/bin/uv 调用）。
# ============================================================

ARG UV_VERSION=0.5.11

RUN curl -LsSf \
    "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    | sh


# 与旧镜像一致：root 和普通 Web Shell 用户都能直接执行
RUN ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes


# ============================================================
# 备份 / 恢复
#
# bz/sync_init.sh    开机从 /mnt/workspace/root 反向恢复
# bz/sync_daemon.sh  实时 rclone 同步 + 每日 05:00 远端快照（防抖版）
# bz/rules.txt       rclone 过滤规则（热文件排除 + v0.23 PM 世代排除）
# ============================================================

COPY bz/ /bz/
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
# 多一个残缺续行符之类的问题，会在构建阶段被发现，
# 而不是等到容器起不来。
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
    && python3 -m py_compile /health/health_server.py \
    && mkdir -p \
        /root/.hermes \
        /root/Desktop \
        /opt/data


# ============================================================
# 构建期断言
#
# 这里只做"看一眼就知道不对"的检查，不执行 hermes 本体
# （镜像里没有 config，执行子命令可能因缺少配置退出非零）。
# ============================================================

RUN set -eu; \
    /usr/local/bin/python3 --version | grep -qE '3\.14' \
        || { echo "Python is not 3.14 — wrong base image"; exit 1; }; \
    test -x /opt/hermes/.venv/bin/hermes \
        || { echo "missing /opt/hermes/.venv/bin/hermes"; exit 1; }; \
    test -d /opt/hermes/hermes_cli/web_dist \
        || { echo "missing prebuilt dashboard web_dist"; exit 1; }; \
    test -d /opt/hermes/apps/desktop/dist-webapp \
        || { echo "missing prebuilt webapp bundle"; exit 1; }; \
    test -x /usr/local/bin/tini-real \
        || { echo "missing tini-real"; exit 1; }; \
    rclone version | head -1; \
    inotifywait --help 2>&1 | head -1; \
    sqlite3 --version \
        || { echo "sqlite3 CLI broken (header/library mismatch?)"; exit 1; }; \
    /usr/local/bin/python3 -c "\
import sqlite3, sys; \
v = tuple(map(int, sqlite3.sqlite_version.split('.'))); \
print('python sqlite', sqlite3.sqlite_version); \
sys.exit('python sqlite too old for the WAL-reset fix') if v < (3, 51, 3) else None; \
db = sqlite3.connect(':memory:'); \
db.execute(\"CREATE VIRTUAL TABLE t USING fts5(c, tokenize='trigram')\"); \
db.execute(\"INSERT INTO t VALUES ('hermes')\"); \
sys.exit('FTS5 trigram self-test failed') if db.execute(\"SELECT count(*) FROM t WHERE t MATCH 'erm'\").fetchone()[0] != 1 else None; \
db.close(); print('FTS5 trigram OK')"; \
    echo "glue layer OK"


# ============================================================
# Ports
#
# 7860  魔塔健康检查 / 状态页（唯一对外端口）
# 9119  dashboard（loopback，走隧道）
# 9120  webapp（loopback，v0.23 新增）
# 2222  ttyd（loopback，走隧道）
# ============================================================

EXPOSE 7860


# ============================================================
# Startup
#
# tini 作为 PID 1：转发 SIGTERM 给 entrypoint，并回收 gateway /
# browser / MCP 这类子进程留下的孤儿，避免僵尸堆积。
# ============================================================

ENTRYPOINT ["/usr/local/bin/tini-real", "--", "/entrypoint.sh"]

CMD ["hermes", "gateway", "run"]
