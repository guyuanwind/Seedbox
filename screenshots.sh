#!/bin/bash
# 视频批量截图脚本，截图后检查大小超10M自动重拍
# 用法: ./screenshots.sh <视频文件路径> <截图保存目录> <时间点1> [时间点2] [...]

check_and_install_bc() {
    if ! command -v bc &>/dev/null; then
        echo "检测到 bc 未安装，正在安装..."
        sudo apt update -y
        sudo apt install -y bc
        if ! command -v bc &>/dev/null; then
            echo "安装 bc 失败，请手动安装后重试。"
            exit 1
        fi
    fi
}

check_and_install_bc

if [ "$#" -lt 3 ]; then
  echo "用法: $0 <视频文件路径> <截图保存目录> <时间点1> [时间点2] [...]"
  exit 1
fi

video="$1"
outdir="$2"

if [ ! -f "$video" ]; then
  echo "错误: 视频文件不存在：$video"
  exit 1
fi

if [ ! -d "$outdir" ]; then
  mkdir -p "$outdir"
fi

# 清空截图保存目录
echo "清空截图目录: $outdir"
rm -rf "${outdir:?}"/*

shift 2

do_screenshot() {
  local timepoint=$1
  local filepath=$2
  local ffmpeg_err
  ffmpeg_err=$(ffmpeg -ss "$timepoint" -i "$video" -map 0:v:0 -y -frames:v 1 -update 1 "$filepath" 2>&1 >/dev/null)
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "截图失败：$filepath"
    echo "原因："
    echo "$ffmpeg_err"
  fi
  return $ret
}

do_screenshot_reencode() {
  local timepoint=$1
  local filepath=$2
  local ffmpeg_err
  ffmpeg_err=$(ffmpeg -ss "$timepoint" -i "$video" -map 0:v:0 -frames:v 1 -y \
    -vf "format=gbrpf32le,zscale=pin=bt2020:p=bt709:t=linear:npl=100,tonemap=hable:desat=0:peak=5,format=rgb24" \
    -c:v png -compression_level 9 -pred mixed "$filepath" 2>&1 >/dev/null)
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "重新压缩截图失败：$filepath"
    echo "原因："
    echo "$ffmpeg_err"
  fi
  return $ret
}

for timepoint in "$@"; do
  minpart=$(echo "$timepoint" | cut -d':' -f2)
  filename="${minpart}min.png"
  filepath="$outdir/$filename"

  echo "正在截图时间点 $timepoint 到文件 $filepath"

  do_screenshot "$timepoint" "$filepath"
  ret=$?

  if [ $ret -ne 0 ]; then
    echo
    continue
  fi

  size_bytes=$(stat -c%s "$filepath")
  size_mb=$(echo "scale=2; $size_bytes/1024/1024" | bc)

  if (( $(echo "$size_mb > 10" | bc -l) )); then
    echo "${filename} 大小为 ${size_mb}MB，超过10M，正在重新压缩截图..."
    do_screenshot_reencode "$timepoint" "$filepath"
    if [ $? -eq 0 ]; then
      echo "${filename} 重新压缩截图成功"
    fi
  else
    echo "${filename} 截图成功"
  fi

  echo
done
