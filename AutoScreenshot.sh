#!/bin/bash
# AutoScreenshot.sh
# 执行截图和上传功能脚本，下载并执行 screenshots.sh 和 PixhostUpload.sh
# 用法:
#   ./AutoScreenshot.sh <视频/ISO/目录> <输出目录> [HH:MM:SS|MM:SS]...

set -euo pipefail

# 颜色
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

# 输出下载脚本的保存路径
download_and_execute() {
    local script_url="$1"
    local script_name="$2"
    local script_path="$SELF_DIR/$script_name"

    echo "[信息] 下载脚本 $script_name ..."
    echo "[信息] 保存路径: $script_path"

    # 使用 wget 下载脚本
    wget -q -O "$script_path" "$script_url" || { err "[错误] 无法下载脚本：$script_name"; exit 1; }

    chmod +x "$script_path"
    echo "[信息] 执行 $script_name ..."
    bash "$script_path" "$INPUT" "$OUTDIR" "$@"
}

if [ "$#" -lt 2 ]; then
  err "用法: $0 <视频/ISO/目录> <输出目录> [时间点...]"
  exit 1
fi

INPUT="$1"; OUTDIR="$2"; shift 2

# 下载并执行 screenshots.sh 脚本
banner "Step 1/2 截图"
download_and_execute "https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/screenshots.sh" "screenshots.sh" "$@"

# 检查截图是否成功
mapfile -t IMGS < <(find "$OUTDIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | sort)
COUNT=${#IMGS[@]}
if [ "$COUNT" -eq 0 ]; then
  err "[错误] 截图目录无图片：$OUTDIR"
  err "（已停止：不执行上传）"
  exit 1
fi
info "[信息] 截图完成，发现 $COUNT 张图片。"

# 下载并执行 PixhostUpload.sh 脚本
banner "Step 2/2 上传到 PixHost"
download_and_execute "https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/PixhostUpload.sh" "PixhostUpload.sh" "$OUTDIR"

banner "全部完成"
