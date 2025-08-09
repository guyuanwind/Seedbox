#!/bin/bash

# 检查是否传入目录参数
if [ -z "$1" ]; then
    echo "用法: $0 <图片文件夹路径>"
    exit 1
fi

# 目标文件夹
DIR="$1"

# 检查目录是否存在
if [ ! -d "$DIR" ]; then
    echo "错误: $DIR 不是一个有效的目录"
    exit 1
fi

# 检查依赖
if ! command -v jq &>/dev/null; then
    echo "错误: 需要安装 jq，请先执行: sudo apt install jq"
    exit 1
fi

if ! command -v curl &>/dev/null; then
    echo "错误: 需要安装 curl，请先执行: sudo apt install curl"
    exit 1
fi

# 遍历目录中的所有图片文件
find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \) | while IFS= read -r image; do
    echo "正在上传: $image"

    # 上传到 pixhost
    varCurl=$(curl -s "https://api.pixhost.to/images" \
      -H 'Accept: application/json' \
      -F "img=@${image}" \
      -F 'content_type=1' \
      -F 'max_th_size=500')

    # 提取 URL
    var1=$(echo "$varCurl" | jq -r '.show_url')
    var2=$(echo "$varCurl" | jq -r '.th_url')

    # 输出 BBCode
    if [ "$var1" != "null" ] && [ "$var2" != "null" ]; then
        echo "[url=$var1][img]$var2[/img][/url]"
    else
        echo "上传失败: $image"
        echo "返回内容: $varCurl"
    fi

    echo "----------------------------------------"
done
