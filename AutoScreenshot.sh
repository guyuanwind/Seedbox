#!/bin/bash
# AutoScreenshot.sh
# 调用 screenshots.sh 完成截图 → 调用 PixhostUpload.sh 批量上传
# 用法:
#   ./AutoScreenshot.sh <视频/ISO/目录> <输出目录> [时间点...]

# 颜色输出
C_RESET='\033[0m'
C_BANNER='\033[1;36m'   # 青色
C_INFO='\033[1;32m'     # 绿色
C_ERR='\033[1;31m'      # 红色

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SS="$SELF_DIR/screenshots.sh"
UP="$SELF_DIR/PixhostUpload.sh"

banner(){ echo -e "\n${C_BANNER}========== $* ==========${C_RESET}\n" >&2; }
info(){ echo -e "${C_INFO}$*${C_RESET}" >&2; }
err(){ echo -e "${C_ERR}$*${C_RESET}" >&2; }

if [ "$#" -lt 2 ]; then
  err "用法: $0 <视频/ISO/目录> <输出目录> [时间点...]"
  exit 1
fi

INPUT="$1"; OUTDIR="$2"; shift 2

# 下载并执行 screenshots.sh 和 PixhostUpload.sh 脚本
download_and_execute() {
    local script_url="$1"
    local script_name="$2"
    local script_path="$SELF_DIR/$script_name"

    echo "[信息] 下载脚本 $script_name ..."
    curl -s -o "$script_path" "$script_url"
    if [ ! -f "$script_path" ]; then
        err "[错误] 无法下载脚本：$script_name"
        exit 1
    fi

    chmod +x "$script_path"
    echo "[信息] 执行 $script_name ..."
    bash "$script_path" "$INPUT" "$OUTDIR" "$@"
}

# 下载并执行截图脚本
download_and_execute "https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/screenshots.sh" "screenshots.sh" "$@"

# 检查产物
mapfile -t IMGS < <(find "$OUTDIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | sort)
COUNT=${#IMGS[@]}
if [ "$COUNT" -eq 0 ]; then
  err "[错误] 截图目录无图片：$OUTDIR"
  err "（已停止：不执行上传）"
  exit 1
fi
info "[信息] 截图完成，发现 $COUNT 张图片。"

# 下载并执行上传脚本
download_and_execute "https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/PixhostUpload.sh" "PixhostUpload.sh"
