#!/bin/bash
# AutoScreenshot.sh
# 该脚本将依次调用 screenshots.sh 和 PixhostUpload.sh
# 本版更新：第一个参数可为"视频文件"或"目录"（含 .mp4/.mkv/.iso/.m2ts 等）
# 新增功能：支持 -jpg 参数切换到高速JPG截图模式
# 新增功能：支持 -fast 参数切换到极速截图模式

# 1) 参数校验和JPG/FAST模式检测
USE_JPG=false
USE_FAST=false
FILTERED_ARGS=()

# 检查所有参数中是否包含 -jpg 或 -fast
for arg in "$@"; do
  if [ "$arg" = "-jpg" ]; then
    USE_JPG=true
  elif [ "$arg" = "-fast" ]; then
    USE_FAST=true
  else
    FILTERED_ARGS+=("$arg")
  fi
done

# 重新设置参数（去除-jpg和-fast）
set -- "${FILTERED_ARGS[@]}"

if [ "$#" -lt 2 ]; then
  echo "[错误] 参数缺失：必须提供【视频文件或目录】和【截图保存目录】。"
  echo "正确用法: $0 <视频文件或目录> <截图保存目录> [时间点...] [-jpg|-fast]"
  echo "  -jpg: 使用高速JPG截图模式（可选，默认PNG模式）"
  echo "  -fast: 使用极速截图模式（可选，默认PNG模式）"
  exit 1
fi

VIDEO_PATH="$1"
SCREENSHOT_DIR="$2"
shift 2  # 移除前两个参数，剩余的都是时间点参数

# 显示当前使用的模式
if [ "$USE_JPG" = true ]; then
  echo "[模式] 高速JPG截图模式已启用"
elif [ "$USE_FAST" = true ]; then
  echo "[模式] 极速截图模式已启用"
else
  echo "[模式] 标准PNG截图模式（默认）"
fi

# 2) 校验“视频输入路径”既可以是文件也可以是目录
if [ ! -e "$VIDEO_PATH" ]; then
  echo "[错误] 视频路径不存在：$VIDEO_PATH"
  exit 1
fi

if [ -f "$VIDEO_PATH" ]; then
  # 是文件（mp4/mkv/ts/m2ts/iso 等均可，由 screenshots.sh 进一步处理）
  if [ ! -r "$VIDEO_PATH" ]; then
    echo "[错误] 视频文件不可读：$VIDEO_PATH"
    exit 1
  fi
  echo "[信息] 检测到视频文件：$VIDEO_PATH"
elif [ -d "$VIDEO_PATH" ]; then
  # 是目录（保持原有目录逻辑由 screenshots.sh 处理）
  echo "[信息] 检测到视频目录：$VIDEO_PATH"
else
  echo "[错误] 输入既不是可读取的视频文件，也不是有效目录：$VIDEO_PATH"
  exit 1
fi

# 3) 检查/创建截图保存目录（保持原逻辑）
if [ ! -d "$SCREENSHOT_DIR" ]; then
  echo "[信息] 截图保存目录不存在，正在创建目录：$SCREENSHOT_DIR"
  mkdir -p "$SCREENSHOT_DIR"
  if [ $? -ne 0 ]; then
    echo "[错误] 创建截图保存目录失败：$SCREENSHOT_DIR"
    exit 1
  fi
fi

# 4) 根据模式选择截图脚本
if [ "$USE_JPG" = true ]; then
  echo "[信息] 调用 screenshots_jpg.sh 进行高速JPG截图..."
  bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/screenshots_jpg.sh) "$VIDEO_PATH" "$SCREENSHOT_DIR" "$@"
  RET=$?
elif [ "$USE_FAST" = true ]; then
  echo "[信息] 调用 screenshots_fast.sh 进行极速截图..."
  bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/screenshots_fast.sh) "$VIDEO_PATH" "$SCREENSHOT_DIR" "$@"
  RET=$?
else
  echo "[信息] 调用 screenshots.sh 进行PNG截图..."
  bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/screenshots.sh) "$VIDEO_PATH" "$SCREENSHOT_DIR" "$@"
  RET=$?
fi

# 5) 若截图成功则上传（核心流程不变）
if [ $RET -eq 0 ]; then
  echo "[信息] 截图完成，开始上传截图..."
  bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/PixhostUpload.sh) "$SCREENSHOT_DIR"
else
  echo "[错误] 截图失败，无法继续上传。"
  exit 1
fi

if [ "$USE_JPG" = true ]; then
  echo "[信息] JPG截图模式操作完成。"
elif [ "$USE_FAST" = true ]; then
  echo "[信息] 极速截图模式操作完成。"
else
  echo "[信息] PNG截图模式操作完成。"
fi
