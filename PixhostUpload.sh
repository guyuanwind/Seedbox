#!/bin/bash
# Pixhost 批量上传脚本，获取原始分辨率大图链接并输出BBCode
# 用法: ./PixhostUploadOriginal.sh <图片文件夹路径>

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

if [ -z "$1" ]; then
    echo "用法: $0 <图片文件夹路径>"
    exit 1
fi

DIR="$1"
if [ ! -d "$DIR" ]; then
    echo "错误: $DIR 不是有效目录"
    exit 1
fi

bbcode_all=""

while IFS= read -r image; do
    echo "正在上传: $image"

    # 上传图片
    response=$(curl -s "https://api.pixhost.to/images" \
        -H 'Accept: application/json' \
        -F "img=@${image}" \
        -F 'content_type=1' \
        -F 'max_th_size=500')

    show_url=$(echo "$response" | jq -r '.show_url')

    if [ "$show_url" = "null" ] || [ -z "$show_url" ]; then
        echo "上传失败: $image"
        echo "返回内容: $response"
        continue
    fi

    echo "图片展示页: $show_url"

    # 请求展示页，解析原始大图链接
    img_url=$(curl -s "$show_url" | grep -oP '(?<=<img id="image" src=")[^"]+')

    if [ -z "$img_url" ]; then
        echo "未能获取原始大图链接，使用缩略图链接代替"
        img_url=$(echo "$response" | jq -r '.th_url')
        if [ "$img_url" = "null" ] || [ -z "$img_url" ]; then
            echo "未获取到任何有效图片链接，跳过 $image"
            continue
        fi
    fi

    echo "原始大图链接: $img_url"

    bbcode="[img]$img_url[/img]"
    bbcode_all="${bbcode_all}${bbcode}\n"

done < <(find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \))

echo -e "\n===== 所有图片 BBCode（原始大图链接） ====="
echo -e "${bbcode_all}"
