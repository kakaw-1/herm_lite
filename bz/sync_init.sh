#!/bin/bash

# ============ 恢复源选择 ============
# RESTORE_SOURCE 取值（自动转小写）：
#   auto   （默认）自动按优先级恢复：workspace → S3 → WebDAV
#   workspace  强制从 /mnt/workspace/root 恢复
#   s3         强制从 S3 远程储存恢复
#   webdav     强制从 WebDAV 远程储存恢复
# 说明：强制模式指定的源当前不可用时，自动回退到 auto 策略。
# ====================================
RESTORE_SOURCE="$(printf '%s' "${RESTORE_SOURCE:-auto}" | tr '[:upper:]' '[:lower:]')"

if [ ! -d "/mnt/workspace" ] && [ -z "${S3_BUCKET}" ] && [ -z "${WEBDAV_URL}" ]; then
    echo "/mnt/workspace 当前为非 ModelScope 环境，且未配置 S3/WEBDAV 远程储存，不执行 Hermes 配置自动恢复任务"
    exit 1
fi

echo "正在恢复容器中 Hermes 的历史配置，请稍后..."

restore_workspace() {
    echo "检测到 /mnt/workspace/root 目录，从本地 /mnt/workspace 恢复配置..."
    rm -rf /mnt/workspace/root/.hermes/hermes-agent > /dev/null 2>&1
    rclone copy /mnt/workspace/root/ /root/ --links --ignore-errors --metadata
}

restore_s3() {
    echo "从 S3 远程储存恢复配置..."
    rclone copyto ":s3:${S3_BUCKET}/${S3_BACKUP_PATH:-backups/data_hermes.tar.gz}" /tmp/data.tar.gz \
        --s3-provider Other \
        --s3-access-key-id "${S3_KEY_ID}" \
        --s3-secret-access-key "${S3_ACCESS_KEY}" \
        --s3-endpoint "${S3_ENDPOINT:-https://s3.cstcloud.cn}" \
        --links --ignore-errors --metadata
    if [ -n "${BACKUP_ENC_PASS}" ]; then
        gpg --batch --yes --passphrase "$BACKUP_ENC_PASS" -d /tmp/data.tar.gz | tar -zxPf - -C / --strip-components 1 > /dev/null 2>&1 || tar -zxPf /tmp/data.tar.gz -C / --strip-components 1 > /dev/null 2>&1 || echo "提示：容器空间首次创建，未找到历史配置信息"
    else
        tar -zxPf /tmp/data.tar.gz -C / --strip-components 1 > /dev/null 2>&1 || echo "提示：容器空间首次创建，未找到历史配置信息"
    fi
}

restore_webdav() {
    if [ -z "${WEBDAV_PASSWD_MASK}" ]; then
        WEBDAV_PASSWD_MASK=$(rclone obscure "${WEBDAV_PASSWD}")
    fi
    echo "从 WEBDAV 远程储存恢复配置..."
    rclone copyto ":webdav:/${WEBDAV_BACKUP_PATH:-backups/data_hermes.tar.gz}" /tmp/data.tar.gz \
        --webdav-vendor other \
        --webdav-url "${WEBDAV_URL}" \
        --webdav-user "${WEBDAV_USER}" \
        --webdav-pass "${WEBDAV_PASSWD_MASK}" \
        --header "User-Agent: ${WEBDAV_CLIENT_UA:-Zotero/8.0}" \
        --links --ignore-errors --metadata
    if [ -n "${BACKUP_ENC_PASS}" ]; then
        gpg --batch --yes --passphrase "$BACKUP_ENC_PASS" -d /tmp/data.tar.gz | tar -zxPf - -C / --strip-components 1 > /dev/null 2>&1 || tar -zxPf /tmp/data.tar.gz -C / --strip-components 1 > /dev/null 2>&1 || echo "提示：容器空间首次创建，未找到历史配置信息"
    else
        tar -zxPf /tmp/data.tar.gz -C / --strip-components 1 > /dev/null 2>&1 || echo "提示：容器空间首次创建，未找到历史配置信息"
    fi
}

# 强制模式：指定的源不可用时，提示并回退 auto
case "${RESTORE_SOURCE}" in
    workspace)
        if [ ! -d "/mnt/workspace/root" ]; then
            echo "RESTORE_SOURCE=workspace 但 /mnt/workspace/root 不存在，回退 auto 自动选择..."
            RESTORE_SOURCE=auto
        fi
        ;;
    s3)
        if [ -z "${S3_BUCKET}" ]; then
            echo "RESTORE_SOURCE=s3 但 S3_BUCKET 未配置，回退 auto 自动选择..."
            RESTORE_SOURCE=auto
        fi
        ;;
    webdav)
        if [ -z "${WEBDAV_URL}" ]; then
            echo "RESTORE_SOURCE=webdav 但 WEBDAV_URL 未配置，回退 auto 自动选择..."
            RESTORE_SOURCE=auto
        fi
        ;;
    auto|*)
        RESTORE_SOURCE=auto
        ;;
esac

# 解析后的恢复流程
if [ "${RESTORE_SOURCE}" = "auto" ]; then
    if [ -d "/mnt/workspace/root" ]; then
        restore_workspace
    elif [ -n "${S3_BUCKET}" ]; then
        restore_s3
    elif [ -n "${WEBDAV_URL}" ]; then
        restore_webdav
    else
        echo "提示：容器空间首次创建，未找到历史配置信息"
    fi
else
    case "${RESTORE_SOURCE}" in
        workspace) restore_workspace ;;
        s3) restore_s3 ;;
        webdav) restore_webdav ;;
    esac
fi

echo "历史配置恢复流程执行完毕"