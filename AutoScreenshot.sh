#!/bin/bash
# AutoScreenshot.sh
# 极简编排：调用 screenshots.sh 完成截图 → 调用 PixhostUpload.sh 批量上传
# 用法:
#   ./AutoScreenshot.sh <视频/ISO/目录> <输出目录> [时间点...] 
# 说明:
#   - 详细日志由 screenshots.sh 与 PixhostUpload.sh 各自负责
#   - 本脚本仅打印阶段标题与简短汇总（走 stderr）
#   - PixhostUpload.sh 的 stdout 为纯净 BBCode 直链，便于复制

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

# 下载脚本
download_scripts() {
    echo "下载截图脚本..."
    curl -o "$SS" https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/screenshots.sh
    curl -o "$UP" https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/PixhostUpload.sh
}

# 检查脚本是否存在
check_scripts() {
    if [ ! -f "$SS" ]; then
        err "[错误] 未找到脚本：$SS"
        exit 1
    fi
    if [ ! -f "$UP" ]; then
        err "[错误] 未找到脚本：$UP"
        exit 1
    fi
}

if [ "$#" -lt 2 ]; then
  err "用法: $0 <视频/ISO/目录> <输出目录> [时间点...]"
  exit 1
fi

INPUT="$1"; OUTDIR="$2"; shift 2

# 下载并检查脚本
download_scripts
check_scripts

# 修正可能的 CRLF（避免 $'\r' 报错）
sed -i 's/\r$//' "$SS" "$UP" 2>/dev/null || true

# Step 1 截图
banner "Step 1/2 截图"
bash "$SS" "$INPUT" "$OUTDIR" "$@"

# 检查产物
mapfile -t IMGS < <(find "$OUTDIR" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | sort)
COUNT=${#IMGS[@]}
if [ "$COUNT" -eq 0 ]; then
  err "[错误] 截图目录无图片：$OUTDIR"
  err "（已停止：不执行上传）"
  exit 1
fi
info "[信息] 截图完成，发现 $COUNT 张图片。"

# Step 2 上传（stderr 加前缀，stdout 纯 BBCode）
banner "Step 2/2 上传到 PixHost"
BBCODE="$(bash "$UP" "$OUTDIR" 2> >(sed -u 's/^/[上传] /' >&2))" || true

echo
if [ -n "$BBCODE" ]; then
  info "[信息] BBCode 原图直链如下："
  echo "$BBCODE"
else
  err "[警告] 未获取到任何 BBCode 直链，请查看上方 [上传] 日志。"
fi

banner "全部完成"
