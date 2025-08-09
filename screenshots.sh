#!/bin/bash
# 视频批量截图脚本
# 用法: ./screenshots.sh <视频文件路径> <截图保存目录> <时间点1> [时间点2] [...]

if [ "$#" -lt 3 ]; then
  echo "用法: $0 <视频文件路径> <截图保存目录> <时间点1> [时间点2] [...]"
  exit 1
fi

video="$1"
outdir="$2"

# 检查视频文件是否存在
if [ ! -f "$video" ]; then
  echo "错误: 视频文件不存在：$video"
  exit 1
fi

# 检查输出目录是否存在，不存在就创建
if [ ! -d "$outdir" ]; then
  mkdir -p "$outdir"
fi

shift 2  # 去除前两个参数，剩下的是时间点

for timepoint in "$@"; do
  # 取时间的分钟部分作为文件名，如 00:05:00 -> 05min.png
  minpart=$(echo "$timepoint" | cut -d':' -f2)
  filename="${minpart}min.png"
  filepath="$outdir/$filename"

  echo "正在截图时间点 $timepoint 到文件 $filepath"

  ffmpeg -ss "$timepoint" -i "$video" -map 0:v:0 -y -frames:v 1 -update 1 "$filepath" >/dev/null 2>&1

  if [ $? -eq 0 ]; then
    echo "${filename}截图成功"
  else
    echo "${filename}截图失败"
  fi
done
