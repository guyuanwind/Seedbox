#!/bin/bash

set -e

FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
FFMPEG_DIR="/usr/local/ffmpeg-master-latest-linux64-gpl"
PROFILE_FILE="/etc/profile"
ENV_LINE='export PATH=$PATH:/usr/local/ffmpeg-master-latest-linux64-gpl/bin'

echo "Downloading FFmpeg..."
curl -LO "$FFMPEG_URL"

echo "Extracting FFmpeg..."
tar -xf ffmpeg-master-latest-linux64-gpl.tar.xz

echo "Copying FFmpeg to $FFMPEG_DIR ..."
sudo rm -rf "$FFMPEG_DIR"   # 先删除旧版本
sudo cp -r ffmpeg-master-latest-linux64-gpl "$FFMPEG_DIR"

echo "Configuring environment variable..."

# 检查是否已存在该行
if grep -Fxq "$ENV_LINE" "$PROFILE_FILE"; then
  # 存在，检查是否在最后一行
  last_line=$(tail -n 1 "$PROFILE_FILE")
  if [ "$last_line" != "$ENV_LINE" ]; then
    # 不在末尾，先删除旧行再追加
    sudo sed -i "\|$ENV_LINE|d" "$PROFILE_FILE"
    echo "" | sudo tee -a "$PROFILE_FILE"
    echo "# Added by FFmpeg install script" | sudo tee -a "$PROFILE_FILE"
    echo "$ENV_LINE" | sudo tee -a "$PROFILE_FILE"
    echo "环境变量已移动到文件末尾"
  else
    echo "环境变量已在文件末尾，无需修改"
  fi
else
  # 不存在，追加到末尾
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
