#!/bin/bash
set -e

# 检测系统架构
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
elif [[ "$ARCH" == "aarch64" ]]; then
    FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
else
    echo "不支持的架构: $ARCH"
    exit 1
fi

FFMPEG_DIR="/usr/local/ffmpeg-master-latest"
PROFILE_FILE="/etc/profile"
ENV_LINE="export PATH=\$PATH:$FFMPEG_DIR/bin"

# 下载
FILE_NAME=$(basename "$FFMPEG_URL")
echo "Detected architecture: $ARCH"
echo "Downloading FFmpeg from: $FFMPEG_URL"
curl -LO "$FFMPEG_URL"

# 解压
echo "Extracting FFmpeg..."
tar -xf "$FILE_NAME"

# 获取解压后的文件夹名
EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "ffmpeg-master-latest-*" | head -n 1)

# 安装
echo "Copying FFmpeg to $FFMPEG_DIR ..."
sudo rm -rf "$FFMPEG_DIR"
sudo cp -r "$EXTRACTED_DIR" "$FFMPEG_DIR"

# 配置环境变量
echo "Configuring environment variable..."
if grep -Fxq "$ENV_LINE" "$PROFILE_FILE"; then
  last_line=$(tail -n 1 "$PROFILE_FILE")
  if [ "$last_line" != "$ENV_LINE" ]; then
    sudo sed -i "\|$ENV_LINE|d" "$PROFILE_FILE"
    echo "" | sudo tee -a "$PROFILE_FILE"
    echo "# Added by FFmpeg install script" | sudo tee -a "$PROFILE_FILE"
    echo "$ENV_LINE" | sudo tee -a "$PROFILE_FILE"
    echo "环境变量已移动到文件末尾"
  else
    echo "环境变量已在文件末尾，无需修改"
  fi
else
  echo "" | sudo tee -a "$PROFILE_FILE"
  echo "# Added by FFmpeg install script" | sudo tee -a "$PROFILE_FILE"
  echo "$ENV_LINE" | sudo tee -a "$PROFILE_FILE"
  echo "环境变量已追加到文件末尾"
fi

echo "Refreshing environment variables..."
source "$PROFILE_FILE"

echo "Verifying FFmpeg installation..."
ffmpeg -version

echo "Done."
