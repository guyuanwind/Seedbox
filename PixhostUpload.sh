#!/bin/bash
# Pixhost 批量上传脚本（去url标签，统一输出BBCode）
# 用法: ./PixhostUpload.sh <图片文件夹路径>

# 自动安装依赖
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

# 参数检查
if [ -z "$1" ]; then
    echo "用法: $0 <图片文件夹路径>"
    exit 1
fi

DIR="$1"

if [ ! -d "$DIR" ]; then
    echo "错误: $DIR 不是一个有效的目录"
    exit 1
fi

# 上传前清空文件夹内容
echo "清空文件夹内容：$DIR"
rm -rf "$DIR"/*

# 存储所有BBCode
bbcode_all=""

# 遍历图片文件列表，避免管道子shell影响变量
while IFS= read -r image; do
    echo "正在上传: $image"

    varCurl=$(curl -s "https://api.pixhost.to/images" \
      -H 'Accept: application/json' \
      -F "img=@${image}" \
      -F 'content_type=1' \
      -F 'max_th_size=500')

    var2=$(echo "$varCurl" | jq -r '.th_url')

    if [ "$var2" != "null" ]; then
        echo "上传成功..."
        bbcode="[img]$var2[/img]"
        bbcode_all="${bbcode_all}${bbcode}\n"
    else
        echo "上传失败: $image"
        echo "返回内容: $varCurl"
    fi
done < <(find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \))

# 统一输出所有BBCode
echo -e "\n===== 所有图片 BBCode（无url标签） ====="
echo -e "${bbcode_all}"
