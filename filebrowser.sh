#!/bin/bash

# 检查参数数量
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <保存目录> <媒体目录>"
    echo "Example:"
    echo "bash <(wget -qO- https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/filebrowser.sh) /data/fb-save /data/fb-media"
    exit 1
fi

SAVE_DIR=$1
MEDIA_DIR=$2

# 自动创建保存目录
mkdir -p "$SAVE_DIR/config"
mkdir -p "$MEDIA_DIR"

# 检查 Docker 是否安装
if ! command -v docker &> /dev/null; then
    echo "Docker 未安装，正在安装..."
    curl -fsSL https://get.docker.com | bash
fi

# 检查容器是否已存在
if docker ps -a --format '{{.Names}}' | grep -w "fb" &> /dev/null; then
    echo "容器 fb 已存在，正在删除..."
    docker rm -f fb
fi

# 部署 FileBrowser 容器
echo "正在部署 80x86/filebrowser..."
docker run -d \
  --name fb \
  --restart unless-stopped \
  -e PUID=0 \
  -e PGID=0 \
  -e WEB_PORT=8082 \
  -e FB_AUTH_SERVER_ADDR=127.0.0.1 \
  -p 8082:8082 \
  -v "${SAVE_DIR}/config:/config" \
  -v "${MEDIA_DIR}:/myfiles" \
  --tmpfs /tmp \
  80x86/filebrowser

# 显示容器状态
docker ps --filter "name=fb"

echo
echo "FileBrowser 部署完成！访问地址: http://<你的服务器IP>:8082 默认账户:admin 默认密码admin"
