#!/bin/bash

set -o pipefail

# ============================================================
# Hermes 配置恢复
#
# RESTORE_SOURCE:
#
# auto       默认。workspace → S3 → WebDAV
# workspace  强制从 /mnt/workspace/root 恢复
# s3         强制从 S3 恢复
# webdav     强制从 WebDAV 恢复
# none       完全跳过恢复
#
# 强制模式失败时不会自动回退，避免灾备时误恢复错误数据。
# ============================================================

RESTORE_SOURCE="$(
    printf '%s' "${RESTORE_SOURCE:-auto}" |
    tr '[:upper:]' '[:lower:]'
)"

echo "Hermes 恢复模式：${RESTORE_SOURCE}"


# ============================================================
# Workspace
# ============================================================

restore_workspace() {

    if [ ! -d "/mnt/workspace/root" ]; then
        echo "错误：/mnt/workspace/root 不存在"
        return 1
    fi

    echo "从 /mnt/workspace 恢复 Hermes 配置..."

    # 不恢复 Hermes 源代码目录
    rm -rf /mnt/workspace/root/.hermes/hermes-agent \
        >/dev/null 2>&1 || true

    if ! rclone copy \
        /mnt/workspace/root/ \
        /root/ \
        --links \
    then
        echo "错误：Workspace 恢复失败"
        return 1
    fi

    echo "Workspace 恢复成功"
    return 0
}


# ============================================================
# 解压远程备份
# ============================================================

extract_remote_backup() {

    local backup_file="$1"

    if [ ! -s "$backup_file" ]; then
        echo "错误：远程备份文件不存在或为空"
        return 1
    fi

    if [ -n "${BACKUP_ENC_PASS:-}" ]; then

        echo "正在解密远程备份..."

        if ! gpg \
            --batch \
            --yes \
            --passphrase "$BACKUP_ENC_PASS" \
            --decrypt "$backup_file" |
            tar -zxPf - \
                -C / \
                --strip-components 1
        then
            echo "错误：远程备份解密或解压失败"
            return 1
        fi

    else

        echo "正在解压未加密远程备份..."

        if ! tar \
            -zxPf "$backup_file" \
            -C / \
            --strip-components 1
        then
            echo "错误：远程备份解压失败"
            return 1
        fi

    fi

    return 0
}


# ============================================================
# S3
# ============================================================

restore_s3() {

    if [ -z "${S3_BUCKET:-}" ]; then
        echo "错误：未配置 S3_BUCKET"
        return 1
    fi

    if [ -z "${S3_KEY_ID:-}" ]; then
        echo "错误：未配置 S3_KEY_ID"
        return 1
    fi

    if [ -z "${S3_ACCESS_KEY:-}" ]; then
        echo "错误：未配置 S3_ACCESS_KEY"
        return 1
    fi

    echo "从 S3 远程储存恢复 Hermes 配置..."

    rm -f /tmp/data_hermes_backup.tar.gz

    if ! rclone copyto \
        ":s3:${S3_BUCKET}/${S3_BACKUP_PATH:-backups/data_hermes.tar.gz}" \
        /tmp/data_hermes_backup.tar.gz \
        --s3-provider Other \
        --s3-access-key-id "${S3_KEY_ID}" \
        --s3-secret-access-key "${S3_ACCESS_KEY}" \
        --s3-endpoint "${S3_ENDPOINT:-https://s3.cstcloud.cn}" \
        --links \
        --metadata
    then
        echo "错误：S3 备份下载失败"
        rm -f /tmp/data_hermes_backup.tar.gz
        return 1
    fi

    if ! extract_remote_backup /tmp/data_hermes_backup.tar.gz; then
        rm -f /tmp/data_hermes_backup.tar.gz
        return 1
    fi

    rm -f /tmp/data_hermes_backup.tar.gz

    echo "S3 恢复成功"
    return 0
}


# ============================================================
# WebDAV
# ============================================================

restore_webdav() {

    if [ -z "${WEBDAV_URL:-}" ]; then
        echo "错误：未配置 WEBDAV_URL"
        return 1
    fi

    if [ -z "${WEBDAV_USER:-}" ]; then
        echo "错误：未配置 WEBDAV_USER"
        return 1
    fi

    if [ -z "${WEBDAV_PASSWD_MASK:-}" ]; then

        if [ -z "${WEBDAV_PASSWD:-}" ]; then
            echo "错误：未配置 WEBDAV_PASSWD"
            return 1
        fi

        WEBDAV_PASSWD_MASK="$(
            rclone obscure "${WEBDAV_PASSWD}"
        )" || {
            echo "错误：WebDAV 密码处理失败"
            return 1
        }

    fi

    echo "从 WebDAV 远程储存恢复 Hermes 配置..."

    rm -f /tmp/data_hermes_backup.tar.gz

    if ! rclone copyto \
        ":webdav:/${WEBDAV_BACKUP_PATH:-backups/data_hermes.tar.gz}" \
        /tmp/data_hermes_backup.tar.gz \
        --webdav-vendor other \
        --webdav-url "${WEBDAV_URL}" \
        --webdav-user "${WEBDAV_USER}" \
        --webdav-pass "${WEBDAV_PASSWD_MASK}" \
        --header "User-Agent: ${WEBDAV_CLIENT_UA:-Zotero/8.0}" \
        --links \
        --metadata
    then
        echo "错误：WebDAV 备份下载失败"
        rm -f /tmp/data_hermes_backup.tar.gz
        return 1
    fi

    if ! extract_remote_backup /tmp/data_hermes_backup.tar.gz; then
        rm -f /tmp/data_hermes_backup.tar.gz
        return 1
    fi

    rm -f /tmp/data_hermes_backup.tar.gz

    echo "WebDAV 恢复成功"
    return 0
}


# ============================================================
# 恢复源选择
# ============================================================

case "${RESTORE_SOURCE}" in

    none)

        echo "RESTORE_SOURCE=none，跳过历史配置恢复"
        exit 0
        ;;


    workspace)

        restore_workspace || exit 1
        ;;


    s3)

        restore_s3 || exit 1
        ;;


    webdav)

        restore_webdav || exit 1
        ;;


    auto)

        if [ -d "/mnt/workspace/root" ]; then

            restore_workspace || exit 1

        elif [ -n "${S3_BUCKET:-}" ]; then

            restore_s3 || exit 1

        elif [ -n "${WEBDAV_URL:-}" ]; then

            restore_webdav || exit 1

        else

            echo "未发现历史配置，视为首次启动"

        fi
        ;;


    *)

        echo "错误：未知 RESTORE_SOURCE=${RESTORE_SOURCE}"
        echo "允许值：auto / workspace / s3 / webdav / none"
        exit 1
        ;;

esac


echo "Hermes 历史配置恢复流程执行完毕"
exit 0
