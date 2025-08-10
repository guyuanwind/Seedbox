#!/bin/bash
# PixHost 批量上传脚本 (仅输出BBCode，强化错误处理)
# 用法: ./PixHostUpload.sh <图片目录路径>

# 颜色定义 (用于错误提示)
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 恢复默认颜色

# 自动安装依赖
check_deps() {
    local pkg missing=()
    for pkg in jq curl; do
        if ! command -v "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装依赖: ${missing[*]}...${NC}"
        if ! sudo apt update -y &>/dev/null || ! sudo apt install -y "${missing[@]}" &>/dev/null; then
            echo -e "${RED}错误: 依赖安装失败，请手动执行:${NC}\nsudo apt update && sudo apt install -y ${missing[*]}" >&2
            exit 1
        fi
    fi
}

# 检查参数
if [ -z "$1" ]; then
    echo -e "${RED}错误: 未指定图片目录路径${NC}" >&2
    echo -e "用法: ${GREEN}$0 <图片目录路径>${NC}" >&2
    exit 1
fi

DIR="$1"
if [ ! -d "$DIR" ]; then
    echo -e "${RED}错误: 目录不存在 [$DIR]${NC}" >&2
    exit 1
fi

# 检查文件是否有效
check_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo -e "${RED}错误: 文件不存在 [$file]${NC}" >&2
        return 1
    fi

    # 文件大小检查 (PixHost限制约10MB)
    local max_size_mb=8
    local size_mb=$(du -m "$file" | cut -f1)
    if [ "$size_mb" -gt "$max_size_mb" ]; then
        echo -e "${YELLOW}警告: 跳过 [$file] (超过 ${max_size_mb}MB)${NC}" >&2
        return 1
    fi

    # 文件类型检查
    if ! file "$file" | grep -qiE 'image|bitmap'; then
        echo -e "${YELLOW}警告: 跳过 [$file] (非图片文件)${NC}" >&2
        return 1
    fi
    return 0
}

# 上传函数 (返回原始大图URL或错误信息)
upload_image() {
    local image="$1"
    local response show_url direct_url

    # 上传到PixHost
    response=$(curl -s "https://api.pixhost.to/images" \
        -H "Accept: application/json" \
        -F "img=@$image" \
        -F "content_type=0" \
        -F "max_th_size=420" 2>&1)

    # 检查curl是否执行失败
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 上传请求失败 [$image]${NC}\n${response}" >&2
        return 1
    fi

    # 检查API返回的有效性
    if ! echo "$response" | jq -e . &>/dev/null; then
        echo -e "${RED}错误: API返回无效JSON [$image]${NC}\n${response}" >&2
        return 1
    fi

    show_url=$(echo "$response" | jq -r '.show_url // empty')
    if [ -z "$show_url" ]; then
        echo -e "${RED}错误: API未返回有效URL [$image]${NC}\n${response}" >&2
        return 1
    fi

    # 从show_url提取原始大图URL
    direct_url=$(echo "$show_url" | sed 's|/th/|/images/|g' | sed 's|_..\.jpg$|.jpg|')
    if [[ ! "$direct_url" =~ ^https:// ]]; then
        echo -e "${RED}错误: 无法生成有效图片URL [$image]${NC}\nShow URL: $show_url" >&2
        return 1
    fi

    echo "$direct_url"
}

# 主处理流程
main() {
    check_deps

    local total=0 success=0
    local image url bbcode

    # 统计总文件数
    total=$(find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \) | wc -l)
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}警告: 目录中未找到图片文件 [$DIR]${NC}" >&2
        exit 0
    fi

    echo -e "${GREEN}开始处理: 共找到 $total 个图片文件${NC}" >&2

    # 遍历处理每个文件
    while IFS= read -r image; do
        if ! check_file "$image"; then
            continue
        fi

        if url=$(upload_image "$image"); then
            ((success++))
            bbcode="[img]$url[/img]"
            echo "$bbcode"  # 仅输出有效的BBCode
        fi
    done < <(find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" \) | sort)

    # 最终状态报告 (输出到stderr避免污染BBCode输出)
    echo -e "\n${GREEN}处理完成!${NC} 成功: ${success}/${total}" >&2
    if [ "$success" -eq 0 ]; then
        echo -e "${RED}错误: 没有文件上传成功${NC}" >&2
        exit 1
    fi
}

# 执行主流程 (错误信息输出到stderr，BBCode输出到stdout)
main 2>&1
