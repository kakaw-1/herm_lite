#!/bin/bash

if [ ! -d "/mnt/workspace" ] && [ -z "${S3_BUCKET}" ] && [ -z "${WEBDAV_URL}" ]; then
    echo "/mnt/workspace 当前为非 ModelScope 环境，且未配置 S3/WEBDAV 远程储存，不执行 Hermes 配置自动恢复任务"
    exit 1
fi

echo "正在恢复容器中 Hermes 的历史配置，请稍后..."

if [ -d "/mnt/workspace/root" ]; then
    echo "检测到 /mnt/workspace/root 目录，优先从本地 /mnt/workspace 恢复配置..."
    rm -rf /mnt/workspace/root/.hermes/hermes-agent > /dev/null 2>&1
    rclone copy /mnt/workspace/root/ /root/ --links --ignore-errors --metadata
elif [ -n "${S3_BUCKET}" ]; then
    echo "检测到 S3_BUCKET 变量，从 S3 远程储存恢复配置..."
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
elif [ -n "${WEBDAV_URL}" ]; then
    if [ -z "${WEBDAV_PASSWD_MASK}" ]; then
        WEBDAV_PASSWD_MASK=$(rclone obscure "${WEBDAV_PASSWD}")
    fi
    echo "检测到 WEBDAV_URL 变量，从 WEBDAV 远程储存恢复配置..."
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
else
    echo "提示：容器空间首次创建，未找到历史配置信息"
fi

echo "历史配置恢复流程执行完毕"
