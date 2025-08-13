#!/bin/bash
# 视频批量截图脚本，截图后检查大小超10M自动重拍
# 用法: ./screenshots.sh <视频文件路径> <截图保存目录> <时间点1> [时间点2] [...]

FIRST_RUN=0

check_and_install_bc() {
    if ! command -v bc &>/dev/null; then
        echo "首次使用检测到缺少依赖：bc"
        echo "正在安装 bc..."
        sudo apt update -y
        sudo apt install -y bc
        if ! command -v bc &>/dev/null; then
            echo "安装 bc 失败，请手动安装后重试。"
            exit 1
        fi
        FIRST_RUN=1
    fi
}

check_and_install_ffmpeg() {
    if ! command -v ffmpeg &>/dev/null; then
        echo "首次使用检测到缺少依赖：ffmpeg"
        echo "正在使用远程安装脚本安装 ffmpeg..."
        bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/install_ffmpeg.sh)
        if ! command -v ffmpeg &>/dev/null; then
            echo "安装 ffmpeg 失败，请手动安装后重试。"
            exit 1
        fi
        FIRST_RUN=1
    fi
}

# 检查依赖
check_and_install_bc
check_and_install_ffmpeg

if [ $FIRST_RUN -eq 1 ]; then
    echo "依赖安装完成，您可以正常使用该脚本进行视频截图。"
    echo
fi

# 参数检查
if [ "$#" -lt 3 ]; then
    echo "错误: 参数不足"
    echo "用法: $0 <视频文件路径> <截图保存目录> <时间点1> [时间点2] [...]"
    exit 1
fi

video="$1"
outdir="$2"
shift 2

# 检查视频文件
if [ ! -f "$video" ]; then
    echo "错误: 视频文件不存在：$video"
    exit 1
fi

# 检查目录
if [ ! -d "$outdir" ]; then
    echo "提示: 截图保存目录不存在，正在创建：$outdir"
    mkdir -p "$outdir" || { echo "错误: 创建目录失败"; exit 1; }
fi

# 检查时间点参数
time_regex='^([0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}$'
for tp in "$@"; do
    if ! [[ $tp =~ $time_regex ]]; then
        echo "错误: 时间点参数 \"$tp\" 格式不正确，应为 HH:MM:SS 或 MM:SS"
        exit 1
    fi
done

# 清空截图保存目录
echo "清空截图目录: $outdir"
rm -rf "${outdir:?}"/*

# 记录开始时间
start_time=$(date +%s)

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

# 记录结束时间并计算耗时
end_time=$(date +%s)
elapsed=$((end_time - start_time))
minutes=$((elapsed / 60))
seconds=$((elapsed % 60))

echo "全部截图完成，用时 ${minutes}分${seconds}秒"
