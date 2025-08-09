#!/bin/bash

# 检查参数数量
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <保存目录> <媒体目录>"
    echo "Example:"
    echo "bash <(wget -qO- https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/publish-helper.sh) /data/save /data/media"
    exit 1
fi

SAVE_DIR=$1
MEDIA_DIR=$2

# 自动创建目录
mkdir -p "$SAVE_DIR/static"
mkdir -p "$SAVE_DIR/temp"
mkdir -p "$MEDIA_DIR"

# 生成 docker-compose.yml
cat > docker-compose.yml <<EOF
version: '3.2'

services:
  publish-helper:
    image: sertion1126/publish-helper:latest
    hostname: publish-helper
    container_name: publish-helper
    restart: always
    networks:
      - publish-helper-network
    environment:
      - API_PORT=15372
      - NGINX_PORT=15373
    volumes:
      - ${SAVE_DIR}/static:/app/static
      - ${SAVE_DIR}/temp:/app/temp
      - ${MEDIA_DIR}:/app/media
    ports:
      - "15372:15372"
      - "15373:15373"

networks:
  publish-helper-network:
    driver: bridge
EOF

echo "docker-compose.yml 已生成"
echo "保存目录: $SAVE_DIR"
echo "媒体目录: $MEDIA_DIR"

# 检查 docker-compose 是否安装
if ! command -v docker-compose &> /dev/null; then
    echo "docker-compose 未安装，正在安装..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# 启动服务
echo "正在启动 publish-helper 服务..."
docker-compose up -d

# 显示容器状态
docker ps --filter "name=publish-helper"
