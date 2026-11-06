# Hermes Lite — 部署说明

镜像：`ghcr.io/kakaw-1/herm-lite`（GitHub Actions 构建，linux/amd64，公开可匿名拉取）

| tag | 含义 |
|---|---|
| `v0.23.0` | 当前升级目标（Hermes v0.23.0 + glue 层） |
| `sha-<commit>` | 每次构建的不可变标签 |
| `latest` | **暂不更新**，仍指向 v2026.8.3（回滚用） |

---

## 1. 底座

```
nousresearch/hermes-agent:v0.23.0   debian trixie + PM + Python 3.14 + sealed venv
        │                            + Node 26 + pinned Chromium
        ▼
     glue 层                          ttyd / cloudflared / rclone / inotify-tools
                                      / openssh-server / sqlite3 / tini / uv
```

上游镜像的 venv 是 **sealed（只读、无 pip）**，装包只能走 `hermes pm install`。

## 2. 魔塔（ModelScope）控制台参数

| 项 | 值 |
|---|---|
| sdk_type | `docker` |
| 镜像 | `ghcr.io/kakaw-1/herm-lite:v0.23.0` |
| 端口 | `7860`（唯一对外端口，health 状态页） |
| 规格 | `platform/2v-cpu-16g-mem` |

环境变量（控制台注入，重建不丢）：

```
HEALTH_PASSWORD=<状态页密码>
HERMES_DASHBOARD=1
HERMES_DASHBOARD_PORT=9119          # 不要用 7860
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=<用户名>   # v0.23 dashboard/webapp 登录门
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<密码>
WEB_SHELL_USER=<用户名>              # 可选，ttyd
WEB_SHELL_PASSWORD=<密码>
```

进程模型：`tini(PID 1)` → `entrypoint.sh` → `gateway run` + `health_server`。
Health 是容器生命周期锚点：gateway 崩了容器仍在，health 退了容器才结束。

## 3. 数据路径

```
/root/.hermes        HERMES_HOME（config / 记忆 / 技能 / cron / 会话 / SOUL.md）
/root/bz-startup/    开机自定义脚本
/mnt/workspace/root  rclone 实时备份镜像（ossfs）
```

不跟随上游默认的 `/opt/data` + UID 10000：本部署以 root 运行，
`HERMES_DOCKER_EXEC_AS_ROOT=1` 关掉上游的降权 shim。

## 4. 备份链

`bz/sync_init.sh` + `bz/sync_daemon.sh`（防抖版）：

- 本地实时：`rclone sync /root/ → /mnt/workspace/root/`，静默 60 s 触发、最小间隔 300 s
- 每日远端：北京 05:00 → `rclone sync /root /tmp/root` → `tar+gpg` → S3（回退 WebDAV）
- 过滤规则：`bz/rules.txt`（热文件 + PM 依赖世代 + 浏览器 profile 排除）

开机：`sync_init.sh` 从 `/mnt/workspace/root` 反向恢复；`SKIP_RESTORE=1` 可跳过。

## 5. 端口

| 端口 | 服务 | 绑定 | 访问方式 |
|---|---|---|---|
| 7860 | health / 状态页 | 0.0.0.0 | 魔塔公开端口 |
| 9119 | dashboard | 127.0.0.1 | 隧道（quick 或 named） |
| 9120 | **webapp**（v0.23 新增） | 127.0.0.1 | 隧道 |
| 2222 | ttyd | 127.0.0.1 | 隧道 |
| 8642 | gateway api_server | 127.0.0.1 | 默认关闭 |

Webapp 默认只在 loopback 可用。要对外需要：

1. `~/.hermes/config.yaml` 加
   ```yaml
   webapp:
     enabled: true
     host: 127.0.0.1
     port: 9120
     public_url: https://<你的域名>
   ```
2. 配好 `HERMES_DASHBOARD_BASIC_AUTH_*`（设了 `public_url` 就会启用登录门）
3. 隧道加一条 ingress：`<域名> → 127.0.0.1:9120`

## 6. 开机序列（entrypoint.sh）

```
tini (PID 1)
 └─ entrypoint.sh
     ├─ 1)  sync_init.sh 恢复 + sync_daemon.sh 实时备份
     ├─ 1b) 镜像升级对齐：config 迁移 → PM 依赖世代对齐 → 内置技能同步
     ├─ 2)  bz-startup/main.sh（飞书 feishu extra 自愈 + resin 后台）
     ├─ 3)  remote-access（ttyd / cloudflared / sshd）
     ├─ 4)  gateway api_server key（默认关）
     ├─ 5)  dashboard（127.0.0.1:9119）
     ├─ 6)  gateway run（只启动一次，不自动拉起）
     └─ 7)  health_server（0.0.0.0:7860，容器生命周期锚点）
```

1b 的三步对应上游 `docker/stage2-hook.sh` 的关键动作，但**不**复用整个 stage2
（它会 usermod / chown -R 把 `/root/.hermes` 属主改成 UID 10000）。
任何一步失败都只记日志，不阻塞启动。

## 7. 回滚

```
魔塔控制台把镜像 tag 改回：ghcr.io/kakaw-1/herm-lite:latest   （= v2026.8.3）
重启容器 → sync_init.sh 从 /mnt/workspace/root 恢复数据
```

`latest` 在 v0.23.0 验证通过前不更新，就是回滚件。
