#!/bin/bash
# PixHost 批量上传脚本 (强制输出原始大图直链)
# 用法: ./PixHostUpload.sh <图片目录路径>

# 颜色定义
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 自动安装依赖
check_deps() {
    for pkg in jq curl; do
        if ! command -v "$pkg" &>/dev/null; then
            echo -e "${YELLOW}正在安装依赖: $pkg...${NC}" >&2
            sudo apt update -y >/dev/null 2>&1 && sudo apt install -y "$pkg" >/dev/null 2>&1 || {
                echo -e "${RED}错误: 安装 $pkg 失败${NC}" >&2
                exit 1
            }
        fi
    done
}

# 检查参数
if [ -z "$1" ]; then
    echo -e "${RED}错误: 必须指定图片目录路径${NC}" >&2
    echo -e "用法: ${GREEN}$0 <图片目录路径>${NC}" >&2
    exit 1
fi

DIR="$1"
if [ ! -d "$DIR" ]; then
    echo -e "${RED}错误: 目录不存在 [$DIR]${NC}" >&2
    exit 1
fi

# 文件验证 (大小/类型)
validate_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo -e "${YELLOW}警告: 文件不存在 [$file]${NC}" >&2
        return 1
    fi

    if ! file "$file" | grep -qiE 'image|bitmap'; then
        echo -e "${YELLOW}警告: 非图片文件 [$file]${NC}" >&2
        return 1
    fi

    local size_mb=$(du -m "$file" | cut -f1)
    if [ "$size_mb" -gt 8 ]; then
        echo -e "${YELLOW}警告: 文件过大 (>8MB) [$file]${NC}" >&2
        return 1
    fi

    return 0
}

# 转换URL为原始直链
convert_to_direct_url() {
    local show_url="$1"
    # 替换方案1: 直接转换域名和路径
    local direct_url=$(echo "$show_url" | sed '
        s|https://pixhost.to/show/|https://img1.pixhost.to/images/|;
        s|https://pixhost.to/th/|https://img1.pixhost.to/images/|;
        s|_...\.jpg$|.jpg|;
    ')
    
    # 替换方案2: 提取ID和文件名重建URL
    if [[ ! "$direct_url" =~ ^https://img1.pixhost.to/images/ ]]; then
        if [[ "$show_url" =~ ([0-9]+)/([^/]+\.(jpg|png|gif)) ]]; then
            direct_url="https://img1.pixhost.to/images/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        fi
    fi

    # 最终验证
    if [[ "$direct_url" =~ ^https://img1.pixhost.to/images/[0-9]+/[^/]+\.(jpg|png|gif)$ ]]; then
        echo "$direct_url"
    else
        echo -e "${RED}错误: 无法转换URL [$show_url]${NC}" >&2
        return 1
    fi
}

# 上传图片并返回直链
upload_image() {
    local image="$1"
    local response show_url direct_url

    response=$(curl -s "https://api.pixhost.to/images" \
        -H "Accept: application/json" \
        -F "img=@$image" \
        -F "content_type=0" \
        -F "max_th_size=420" 2>&1)

    # 检查curl执行状态
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 上传请求失败 [$image]${NC}" >&2
        return 1
    fi

    # 检查API响应
    if ! jq -e . >/dev/null 2>&1 <<<"$response"; then
        echo -e "${RED}错误: API返回无效JSON [$image]${NC}" >&2
        return 1
    fi

    show_url=$(jq -r '.show_url // empty' <<<"$response")
    if [ -z "$show_url" ]; then
        echo -e "${RED}错误: API未返回有效URL [$image]${NC}" >&2
        return 1
    fi

    # 转换为原始直链
    if ! direct_url=$(convert_to_direct_url "$show_url"); then
        return 1
    fi

    echo "$direct_url"
}

# 主流程
main() {
    check_deps
    local total=0 success=0

    # 统计有效文件
    total=$(find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \) | wc -l)
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}警告: 未找到有效图片文件${NC}" >&2
        exit 0
    fi

    echo -e "${GREEN}开始处理 $total 个文件...${NC}" >&2

    # 处理文件
    while IFS= read -r image; do
        if ! validate_file "$image"; then
            continue
        fi

        if direct_url=$(upload_image "$image"); then
            ((success++))
            echo "$direct_url"  # 直接输出原始大图链接
        fi
    done < <(find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \) | sort)

    # 结果统计
    echo -e "\n${GREEN}处理完成! 成功: ${success}/${total}${NC}" >&2
    [ "$success" -eq 0 ] && exit 1 || exit 0
}

# 执行 (标准输出只包含URL)
main
