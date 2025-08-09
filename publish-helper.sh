#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <保存目录> <媒体目录>"
    exit 1
fi

SAVE_DIR=$1
MEDIA_DIR=$2

# 创建目录（不存在则创建）
mkdir -p "$SAVE_DIR/static"
mkdir -p "$SAVE_DIR/temp"
mkdir -p "$MEDIA_DIR"

# 生成docker-compose.yml
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

echo "docker-compose.yml 已生成，保存目录: $SAVE_DIR ，媒体目录: $MEDIA_DIR"

# 可选：启动服务
# docker-compose up -d
