#!/bin/bash
# 批量上传指定文件夹所有图片到 Pixhost，并生成 BBCode
# 用法: ./PixhostUpload.sh <图片文件夹路径>

# ========= 自动安装依赖 =========
check_and_install() {
    local pkg=$1
    if ! command -v "$pkg" &>/dev/null; then
        echo "检测到 $pkg 未安装，正在安装..."
        sudo apt update -y
        sudo apt install -y "$pkg"
    fi
}

check_and_install jq
check_and_install curl

# ========= 参数检查 =========
if [ -z "$1" ]; then
    echo "用法: $0 <图片文件夹路径>"
    exit 1
fi

DIR="$1"

if [ ! -d "$DIR" ]; then
    echo "错误: $DIR 不是一个有效的目录"
    exit 1
fi

# ========= 上传逻辑 =========
find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \) | while IFS= read -r image; do
    echo "正在上传: $image"

    # 上传到 pixhost API
    varCurl=$(curl -s "https://api.pixhost.to/images" \
      -H 'Accept: application/json' \
      -F "img=@${image}" \
      -F 'content_type=1' \
      -F 'max_th_size=500')

    # 解析 JSON
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
