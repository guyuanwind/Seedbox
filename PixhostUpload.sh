#!/bin/bash
# PixHost 批量上传脚本 (输出BBCode格式的原始大图直链)
# 用法: ./PixHostUpload.sh <图片目录路径>

# 颜色定义 (错误提示)
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 依赖检查
check_deps() {
    for pkg in jq curl; do
        if ! command -v "$pkg" &>/dev/null; then
            echo -e "${YELLOW}正在安装依赖: $pkg...${NC}" >&2
            sudo apt update -y >/dev/null 2>&1 && sudo apt install -y "$pkg" >/dev/null 2>&1 || {
                echo -e "${RED}错误: $pkg 安装失败${NC}" >&2
                exit 1
            }
        fi
    done
}

# 参数检查
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

# 文件验证
validate_file() {
    local file="$1"
    [[ ! -f "$file" ]] && { echo -e "${YELLOW}警告: 文件不存在 [$file]${NC}" >&2; return 1; }
    file "$file" | grep -qiE 'image|bitmap' || { echo -e "${YELLOW}警告: 非图片文件 [$file]${NC}" >&2; return 1; }
    [ $(du -m "$file" | cut -f1) -gt 10 ] && { echo -e "${YELLOW}警告: 文件过大 (>10MB) [$file]${NC}" >&2; return 1; }
    return 0
}

# URL转换器 (确保获取img1.pixhost.to原始直链)
convert_to_direct_url() {
    local show_url="$1"
    # 方案1: 直接替换域名和路径
    local direct_url=$(echo "$show_url" | sed '
        s|https://pixhost.to/show/|https://img1.pixhost.to/images/|;
        s|https://pixhost.to/th/|https://img1.pixhost.to/images/|;
        s|_...\.jpg$|.jpg|;
    ')
    
    # 方案2: 正则提取重建URL
    [[ "$direct_url" =~ ^https://img1.pixhost.to/images/ ]] || {
        [[ "$show_url" =~ ([0-9]+)/([^/]+\.(jpg|png|gif)) ]] &&
        direct_url="https://img1.pixhost.to/images/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    }

    # 最终验证
    [[ "$direct_url" =~ ^https://img1.pixhost.to/images/[0-9]+/[^/]+\.(jpg|png|gif)$ ]] && {
        echo "$direct_url"
    } || {
        echo -e "${RED}错误: URL转换失败 [$show_url]${NC}" >&2
        return 1
    }
}

# 上传函数
upload_image() {
    local image="$1"
    local response show_url direct_url

    response=$(curl -s "https://api.pixhost.to/images" \
        -H "Accept: application/json" \
        -F "img=@$image" \
        -F "content_type=0" \
        -F "max_th_size=420" 2>&1) || {
        echo -e "${RED}错误: 上传请求失败 [$image]${NC}" >&2
        return 1
    }

    jq -e . >/dev/null 2>&1 <<<"$response" || {
        echo -e "${RED}错误: API返回无效JSON [$image]${NC}" >&2
        echo "$response" >&2
        return 1
    }

    show_url=$(jq -r '.show_url // empty' <<<"$response")
    [ -z "$show_url" ] && {
        echo -e "${RED}错误: API未返回有效URL [$image]${NC}" >&2
        echo "$response" >&2
        return 1
    }

    convert_to_direct_url "$show_url"
}

# 主流程
main() {
    check_deps
    local total=0 success=0

    # 统计文件
    total=$(find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \) | wc -l)
    [ "$total" -eq 0 ] && {
        echo -e "${YELLOW}警告: 未找到有效图片文件${NC}" >&2
        exit 0
    }

    echo -e "${GREEN}开始处理 $total 个文件...${NC}" >&2

    # 处理文件
    while IFS= read -r image; do
        validate_file "$image" || continue
        
        if direct_url=$(upload_image "$image"); then
            ((success++))
            echo "[img]$direct_url[/img]"  # 输出BBCode格式
        fi
    done < <(find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \) | sort)

    # 结果报告
    echo -e "\n${GREEN}处理完成! 成功: ${success}/${total}${NC}" >&2
    [ "$success" -eq 0 ] && exit 1 || exit 0
}

# 执行 (纯净BBCode输出)
main
