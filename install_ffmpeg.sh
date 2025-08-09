#!/bin/bash
set -e

# 检查并安装依赖
for cmd in curl tar xz; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "缺少依赖: $cmd，正在安装..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y $cmd
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y $cmd
        else
            echo "无法自动安装依赖，请手动安装 $cmd"
            exit 1
        fi
    fi
done

# 检测系统架构
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

PROFILE_FILE="/etc/profile"

# 清理旧文件
echo "清理旧版本..."
rm -rf ffmpeg-master-latest-* ffmpeg*.tar.xz

# 下载 FFmpeg
FILE_NAME=$(basename "$FFMPEG_URL")
echo "检测到架构: $ARCH"
echo "正在下载 FFmpeg: $FFMPEG_URL"
curl -fLO "$FFMPEG_URL"

# 解压
echo "解压 FFmpeg..."
tar -xf "$FILE_NAME"

# 获取解压后的目录名
EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "ffmpeg-master-latest-*" | head -n 1)
if [[ -z "$EXTRACTED_DIR" ]]; then
    echo "解压失败，未找到 FFmpeg 目录"
    exit 1
fi

FFMPEG_DIR="/usr/local/$EXTRACTED_DIR"

# 安装
echo "安装 FFmpeg 到 $FFMPEG_DIR ..."
sudo rm -rf "$FFMPEG_DIR"
sudo mv "$EXTRACTED_DIR" "$FFMPEG_DIR"

# 配置环境变量
ENV_LINE="export PATH=\$PATH:$FFMPEG_DIR/bin"
if ! grep -Fxq "$ENV_LINE" "$PROFILE_FILE"; then
    echo "" | sudo tee -a "$PROFILE_FILE"
    echo "# Added by FFmpeg install script" | sudo tee -a "$PROFILE_FILE"
    echo "$ENV_LINE" | sudo tee -a "$PROFILE_FILE"
    echo "已将 FFmpeg 路径写入 $PROFILE_FILE"
else
    echo "FFmpeg 路径已存在于 $PROFILE_FILE"
fi

# 验证安装
echo "安装完成，请运行以下命令以立即生效："
echo "source $PROFILE_FILE"
echo "验证 FFmpeg 版本："
echo "$ ffmpeg -version"
