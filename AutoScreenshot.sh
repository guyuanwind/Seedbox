#!/bin/bash
# AutoScreenshot.sh
# 该脚本将依次调用 screenshots.sh 和 PixhostUpload.sh

# 确保传递了正确的参数
if [ "$#" -lt 2 ]; then
  echo "[错误] 参数缺失：必须提供视频目录和截图保存目录。"
  echo "正确用法: $0 <视频目录> <截图保存目录> [时间点...]"
  exit 1
fi

VIDEO_DIR="$1"
SCREENSHOT_DIR="$2"
shift 2  # 移除前两个参数，剩余的都是时间点参数

# 检查视频目录是否存在
if [ ! -d "$VIDEO_DIR" ]; then
  echo "[错误] 视频目录不存在：$VIDEO_DIR"
  exit 1
fi

# 检查截图保存目录是否有效
if [ ! -d "$SCREENSHOT_DIR" ]; then
  echo "[错误] 截图保存目录不存在：$SCREENSHOT_DIR"
  exit 1
fi

# 调用 screenshots.sh 进行截图
echo "[信息] 调用 screenshots.sh 进行截图..."
bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/screenshots.sh) "$VIDEO_DIR" "$SCREENSHOT_DIR" "$@"

# 如果截图成功，调用 PixhostUpload.sh 上传截图
if [ $? -eq 0 ]; then
  echo "[信息] 截图完成，开始上传截图..."
  bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/PixhostUpload.sh) "$SCREENSHOT_DIR"
else
  echo "[错误] 截图失败，无法继续上传。"
  exit 1
fi

echo "[信息] 操作完成。"
