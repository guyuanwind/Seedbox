#!/bin/bash
set -e

# ========= 函数 =========
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "请以 root 用户或使用 sudo 运行此脚本"
        exit 1
    fi
}

remove_old_ffmpeg() {
    echo "检查并清理旧版本 FFmpeg..."
    # 删除 apt/yum 安装的 ffmpeg
    if command -v ffmpeg >/dev/null 2>&1; then
        OLD_PATH=$(command -v ffmpeg)
        echo "发现已安装 FFmpeg: $OLD_PATH"
        apt-get remove -y ffmpeg 2>/dev/null || yum remove -y ffmpeg 2>/dev/null || true
    fi
    # 删除本地安装的 ffmpeg 目录
    rm -rf /usr/local/ffmpeg-master-latest-* 2>/dev/null || true
    # 删除 /etc/profile 中旧的 FFmpeg PATH
    sed -i '/# Added by FFmpeg install script/d' /etc/profile
    sed -i '/ffmpeg-master-latest-/d' /etc/profile
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
            ;;
        aarch64)
            FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
            ;;
        *)
            echo "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    echo "检测到架构: $ARCH"
}

download_ffmpeg() {
    FILE_NAME=$(basename "$FFMPEG_URL")
    echo "正在下载 FFmpeg: $FFMPEG_URL"
    curl -L -o "$FILE_NAME" "$FFMPEG_URL"
    if [[ ! -f "$FILE_NAME" ]]; then
        echo "下载失败"
        exit 1
    fi
}

extract_and_install() {
    echo "解压 FFmpeg..."
    tar -xf "$FILE_NAME"

    EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "ffmpeg-master-latest-*" | head -n 1)
    if [[ ! -d "$EXTRACTED_DIR" ]]; then
        echo "解压失败"
        exit 1
    fi

    FFMPEG_DIR="/usr/local/$EXTRACTED_DIR"
    echo "安装 FFmpeg 到 $FFMPEG_DIR ..."
    mv "$EXTRACTED_DIR" "$FFMPEG_DIR"

    ENV_LINE="export PATH=\$PATH:$FFMPEG_DIR/bin"
    {
        echo "# Added by FFmpeg install script"
        echo "$ENV_LINE"
    } >> /etc/profile

    echo "已将 FFmpeg 路径写入 /etc/profile"
}

verify_install() {
    echo "刷新环境变量..."
    source /etc/profile
    hash -r
    echo "当前 FFmpeg 版本:"
    ffmpeg -version
}

# ========= 主流程 =========
check_root
remove_old_ffmpeg
detect_arch
download_ffmpeg
extract_and_install
verify_install

echo "安装完成！"
