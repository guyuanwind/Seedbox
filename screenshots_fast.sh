#!/bin/bash
# 高速截图脚本（无字幕版本）
# - 保留：目录智能识别、原始分辨率、文件大小控制
# - 移除：所有字幕处理逻辑
# - 优化：最大化截图速度，确保文件小于10MB
# - 输入：视频文件 / ISO / 目录
# - 时间点：提供则直接使用；未提供则自动取 20%/40%/60%/80%
# 用法：
#   ./screenshots_fast.sh <视频/ISO/目录> <输出目录> [HH:MM:SS|MM:SS] [...]

set -u
log(){ echo -e "$*" >&2; }

FIRST_RUN=0
success_count=0
fail_count=0
failed_files=()
failed_reasons=()

time_regex='^([0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}$'

# —— 速度优化参数
PROBESIZE="50M"                 # 大幅减少探测数据量
ANALYZE="50M"                   # 大幅减少分析时间
COARSE_BACK=1                   # 最小预滚动时间
AUTO_PERC=("0.20" "0.40" "0.60")

# JPG质量参数（速度优化）
JPG_QUALITY=75                  # 降低质量以提升速度
JPG_QUALITY_RETRY=60            # 重拍时的更低质量

MOUNTED=0
MOUNT_DIR=""
ISO_PATH=""
M2TS_INPUT=""
START_OFFSET="0.0"
DURATION="0.0"

# —— 工具函数（保持不变）
lower(){ echo "$1" | tr '[:upper:]' '[:lower:]'; }
is_iso(){
  case "${1##*.}" in
    [iI][sS][oO]) return 0 ;;
    *)            return 1 ;;
  esac
}
hms_to_seconds(){ local t="$1" h=0 m=0 s=0; IFS=':' read -r a b c <<<"$t"; if [ -z "${c:-}" ]; then m=$a; s=$b; else h=$a; m=$b; s=$c; fi; echo $((10#$h*3600 + 10#$m*60 + 10#$s)); }
sec_to_hms(){ local x=${1%.*}; printf "%02d:%02d:%02d" $((x/3600)) $(((x%3600)/60)) $((x%60)); }
fadd(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f",a+b}'; }
fsub(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f",a-b}'; }
clamp_0_dur(){ awk -v t="$1" -v mx="$DURATION" 'BEGIN{if(t<0)t=0; if(t>mx)t=mx; printf "%.3f",t}'; }

cleanup(){
  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    log "[清理] 正在卸载 ISO：$MOUNT_DIR"
    if sudo umount "$MOUNT_DIR" 2>/tmp/umount_err.log; then
      log "[清理] 卸载成功，删除临时目录"
      rmdir "$MOUNT_DIR" 2>/dev/null && log "[清理] 已删除临时目录 $MOUNT_DIR"
    else
      log "[警告] 卸载失败："; cat /tmp/umount_err.log >&2
    fi
    rm -f /tmp/umount_err.log
  fi
}
trap 'cleanup' EXIT INT TERM

# —— 依赖检查
check_and_install_bc(){
  if ! command -v bc >/dev/null 2>&1; then
    log "[依赖检测] 缺少 bc，正在安装..."
    sudo apt update -y && sudo apt install -y bc || { log "[错误] 安装 bc 失败"; exit 1; }
    FIRST_RUN=1
  fi
}
check_and_install_ffmpeg(){
  if ! command -v ffmpeg >/dev/null 2>&1; then
    log "[依赖检测] 缺少 ffmpeg，正在安装..."
    bash <(curl -s https://raw.githubusercontent.com/guyuanwind/Seedbox/refs/heads/main/install_ffmpeg.sh) || true
    command -v ffmpeg >/dev/null 2>&1 || { log "[错误] 安装 ffmpeg 失败"; exit 1; }
    FIRST_RUN=1
  fi
}

validate_arguments(){
  if [ "$#" -lt 2 ]; then
    echo "[错误] 参数缺失：必须提供视频文件/ISO/目录和截图输出目录。"
    echo "正确用法: $0 <视频/ISO/目录> <输出目录> [时间点...]"
    exit 1
  fi

  local p="$1" outdir="$2"
  
  if [ ! -f "$p" ] && [ ! -d "$p" ]; then
    echo "[错误] 视频文件或目录不存在：$p"
    echo "正确用法: $0 <视频/ISO/目录> <输出目录> [时间点...]"
    exit 1
  fi

  if [ -z "$outdir" ]; then
    echo "[错误] 参数缺失：必须提供截图输出目录。"
    echo "正确用法: $0 <视频/ISO/目录> <输出目录> [时间点...]"
    exit 1
  fi

  if [ ! -d "$outdir" ]; then
    log "[提示] 输出目录不存在，正在创建：$outdir"
    mkdir -p "$outdir" || { log "[错误] 创建输出目录失败：$outdir"; exit 1; }
  fi

  shift 2
  for t in "$@"; do
    if [[ ! "$t" =~ ^([0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}$ ]]; then
      echo "[错误] 时间点格式不正确：$t"
      echo "正确格式: 00:30:00 或 30:00"
      exit 1
    fi
  done
}

# —— ISO & m2ts（保持原有逻辑）
mount_iso(){
  ISO_PATH="$1"
  local iso_dir iso_base ts
  iso_dir="$(cd "$(dirname "$ISO_PATH")" && pwd)"
  iso_base="$(basename "$ISO_PATH" .iso)"
  ts="$(date +%s)"
  MOUNT_DIR="${iso_dir}/.${iso_base}_mnt_${ts}_$$"
  mkdir -p "$MOUNT_DIR" || { log "[错误] 创建挂载目录失败：$MOUNT_DIR"; exit 1; }

  log "[提示] 识别到 ISO 文件：$ISO_PATH"
  log "[信息] 挂载 ISO -> $MOUNT_DIR"
  if ! sudo mount -o loop "$ISO_PATH" "$MOUNT_DIR" 2>/tmp/mount_err.log; then
    log "[错误] 挂载 ISO 失败："; cat /tmp/mount_err.log >&2
    rm -f /tmp/mount_err.log; rmdir "$MOUNT_DIR" 2>/dev/null; exit 1
  fi
  rm -f /tmp/mount_err.log
  MOUNTED=1
}

find_largest_m2ts_in_dir(){
  local root="$1" search_root="$1"
  [ -d "$root/BDMV/STREAM" ] && search_root="$root/BDMV/STREAM"
  log "[信息] 在目录中搜索最大 .m2ts：$search_root"
  local biggest
  biggest=$(find "$search_root" -type f -iname '*.m2ts' -printf '%s %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
  [ -z "$biggest" ] && { log "[错误] 目录中未找到 .m2ts 文件"; return 1; }
  log "[信息] 选定最大 m2ts：$biggest"
  M2TS_INPUT="$biggest"; return 0
}

find_largest_m2ts(){
  local base_dir="$1" search_root
  if [ -d "$base_dir/BDMV/STREAM" ]; then search_root="$base_dir/BDMV/STREAM"
  else search_root="$base_dir"; log "[提示] 未找到 BDMV/STREAM，回退全盘搜索"; fi
  log "[信息] 正在搜索最大 m2ts 文件于：$search_root"
  local max_size=0 max_file="" sz
  while IFS= read -r -d '' f; do
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$sz" =~ ^[0-9]+$ ]] || continue
    if [ "$sz" -gt "$max_size" ]; then max_size="$sz"; max_file="$f"; fi
  done < <(find "$search_root" -type f -iname '*.m2ts' -print0)
  [ -z "$max_file" ] && { log "[错误] 未找到 .m2ts"; return 1; }
  log "[信息] 选定最大 m2ts：$max_file （大小：$((max_size/1024/1024)) MB）"
  M2TS_INPUT="$max_file"; return 0
}

# —— 目录选择逻辑（保持原有完整逻辑）
select_input_from_arg(){
  local input="$1"

  if [ -f "$input" ]; then
    if is_iso "$input"; then
      mount_iso "$input"
      find_largest_m2ts "$MOUNT_DIR" || { echo "[错误] ISO 内无 .m2ts"; exit 1; }
      video="$M2TS_INPUT"
      log "[信息] 将使用 m2ts 文件：$video"
      return 0
    fi
    video="$input"
    log "[信息] 识别到视频文件，直接截图：$video"
    return 0
  fi

  if [ -d "$input" ]; then
    log "[提示] 输入为目录，开始智能识别..."
    local iso
    iso=$(find "$input" -maxdepth 1 -type f -iname '*.iso' -printf '%s %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
    if [ -n "$iso" ]; then
      mount_iso "$iso"
      find_largest_m2ts "$MOUNT_DIR" || { echo "[错误] ISO 内无 .m2ts"; exit 1; }
      video="$M2TS_INPUT"
      log "[信息] 将使用 m2ts 文件：$video"
      return 0
    fi
    if [ -d "$input/BDMV/STREAM" ]; then
      find_largest_m2ts_in_dir "$input" || { echo "[错误] 目录内无 .m2ts"; exit 1; }
      video="$M2TS_INPUT"
      log "[信息] 将使用 m2ts 文件：$video"
      return 0
    fi
    local -a vids=()
    while IFS= read -r -d '' f; do vids+=("$f"); done < <(
      find "$input" -maxdepth 1 -type f \
        \( -iregex '.*\.\(mkv\|mp4\|mov\|m4v\|avi\|ts\|m2ts\|webm\|wmv\|flv\|rmvb\|mpeg\|mpg\)' \) -print0 2>/dev/null
    )
    if [ ${#vids[@]} -eq 0 ]; then
      echo "[错误] 目录内未发现可用视频文件（无 ISO/BDMV/常见视频）。"; exit 1
    fi
    if [ ${#vids[@]} -eq 1 ]; then
      video="${vids[0]}"; log "[信息] 选定视频：$video"; return 0
    fi
    local -a e01=()
    for f in "${vids[@]}"; do
      local filename="${f##*/}"
      if echo "$filename" | grep -qiE '(e0?1([^0-9]|$)|第一集|第1集|episode.?1|ep.?1|pilot)'; then 
        e01+=("$f")
      fi
    done
    if [ ${#e01[@]} -gt 0 ]; then
      local largest="" max=0 sz
      for f in "${e01[@]}"; do
        sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if [ "$sz" -gt "$max" ]; then max=$sz; largest="$f"; fi
      done
      video="$largest"
      log "[信息] 多个视频，优先选择包含第一集的：$video"
      return 0
    fi
    local biggest
    biggest=$(printf '%s\0' "${vids[@]}" | xargs -0 -I{} stat -c '%s %n' "{}" | sort -nr | head -1 | cut -d' ' -f2-)
    video="$biggest"
    log "[提示] 多个视频但未发现第一集，改选体积最大：$video"
    return 0
  fi

  echo "[错误] 无法识别输入路径：$input"; exit 1
}

detect_start_offset(){
  local off
  off=$(ffprobe -v error -select_streams v:0 -show_entries stream=start_time -of default=noprint_wrappers=1:nokey=1 "$video" 2>/dev/null | head -n1)
  [[ "$off" =~ ^[0-9] ]] || off=$(ffprobe -v error -show_entries format=start_time -of default=noprint_wrappers=1:nokey=1 "$video" 2>/dev/null | head -n1)
  START_OFFSET="${off:-0.0}"
}

detect_duration(){
  local d
  d=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video" 2>/dev/null | head -n1)
  [[ "$d" =~ ^[0-9] ]] || d=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 "$video" 2>/dev/null | head -n1)
  DURATION="${d:-0.0}"
}

# —— 极速截图函数（无字幕处理）
do_screenshot(){
  local t_aligned="$1" path="$2" err
  local tnum="${t_aligned%.*}"; [[ "$tnum" =~ ^[0-9]+$ ]] || tnum=0
  local coarse_sec=$(( tnum > COARSE_BACK ? tnum - COARSE_BACK : 0 ))
  local fine_sec="$(fsub "$t_aligned" "$coarse_sec")"
  local coarse_hms="$(sec_to_hms "$coarse_sec")"

  # 极速截图：无字幕处理，最小参数集
  err=$(ffmpeg -v error -fflags +genpts -ss "$coarse_hms" -probesize "$PROBESIZE" -analyzeduration "$ANALYZE" \
    -i "$video" -ss "$fine_sec" -map 0:v:0 -frames:v 1 \
    -c:v mjpeg -q:v "$JPG_QUALITY" -y "$path" 2>&1)
  
  local ret=$?
  if [ $ret -ne 0 ]; then failed_files+=("$(basename "$path")"); failed_reasons+=("$err"); fi
  return $ret
}

do_screenshot_reencode(){
  local t_aligned="$1" path="$2" err
  local tnum="${t_aligned%.*}"; [[ "$tnum" =~ ^[0-9]+$ ]] || tnum=0
  local coarse_sec=$(( tnum > COARSE_BACK ? tnum - COARSE_BACK : 0 ))
  local fine_sec="$(fsub "$t_aligned" "$coarse_sec")"
  local coarse_hms="$(sec_to_hms "$coarse_sec")"

  # 重拍：更低质量确保小于10MB
  err=$(ffmpeg -v error -fflags +genpts -ss "$coarse_hms" -probesize "$PROBESIZE" -analyzeduration "$ANALYZE" \
    -i "$video" -ss "$fine_sec" -map 0:v:0 -frames:v 1 \
    -c:v mjpeg -q:v "$JPG_QUALITY_RETRY" -y "$path" 2>&1)
  
  local ret=$?
  if [ $ret -ne 0 ]; then failed_files+=("$(basename "$path")"); failed_reasons+=("$err"); fi
  return $ret
}

# ---------------- 主流程 ----------------
check_and_install_bc
check_and_install_ffmpeg
[ $FIRST_RUN -eq 1 ] && { log "[提示] 首次运行依赖安装完成。"; log ""; }

validate_arguments "$@"

input_path="$1"; outdir="$2"; shift 2

# 根据输入选择实际视频文件
video=""
select_input_from_arg "$input_path"

# 时长检测（无字幕选择）
detect_start_offset
detect_duration
DURATION_HMS="$(sec_to_hms ${DURATION%.*})"

log "[信息] 极速截图模式（无字幕）| JPG质量：$JPG_QUALITY"
log "[信息] 容器起始偏移：${START_OFFSET}s | 影片总时长：${DURATION_HMS}"

log "[信息] 清空截图目录: $outdir"
rm -rf "${outdir:?}"/*

declare -a TARGET_SECONDS=()
if [ "$#" -gt 0 ]; then
  log "[信息] 已提供时间点：直接截图（无字幕对齐）"
  for tp in "$@"; do TARGET_SECONDS+=( "$(hms_to_seconds "$tp")" ); done
else
  log "[信息] 未提供时间点：自动按 20% / 40% / 60% 选取（3张截图）"
  if awk -v d="$DURATION" 'BEGIN{exit !(d>0)}'; then
    for p in "${AUTO_PERC[@]}"; do
      t=$(awk -v d="$DURATION" -v p="$p" 'BEGIN{t=d*p; if(t<5)t=5; if(t>d-5)t=d-5; printf "%.3f",t}')
      TARGET_SECONDS+=( "$t" )
    done
  else
    log "[警告] 时长未知，退化为固定时间点：300/900/1800/2700 秒"
    TARGET_SECONDS=(300 900 1800 2700)
  fi
fi

start_time=$(date +%s)
idx=0
for T_req in "${TARGET_SECONDS[@]}"; do
  idx=$((idx+1))
  T_align="$(clamp_0_dur "$T_req")"
  [ "${T_align:0:1}" = "." ] && T_align="0${T_align}"

  if [ "$#" -gt 0 ]; then
    minpart=$(( ${T_req%.*} / 60 ))
    filename="${minpart}min.jpg"
  else
    filename="fast${idx}.jpg"
  fi
  filepath="$outdir/$filename"

  log "[信息] 极速截图: $(sec_to_hms ${T_req%.*}) -> $filename"

  # 执行截图
  do_screenshot "$T_align" "$filepath"
  if [ $? -ne 0 ]; then ((fail_count++)); continue; fi

  # 检查文件大小，如超过10MB则重拍
  size_bytes=$(stat -c%s "$filepath")
  size_mb=$(echo "scale=2; $size_bytes/1024/1024" | bc)
  if (( $(echo "$size_mb > 10" | bc -l) )); then
    log "[提示] $filename 大小 ${size_mb}MB，重拍降低质量..."
    do_screenshot_reencode "$T_align" "$filepath"
    [ $? -eq 0 ] && ((success_count++)) || ((fail_count++))
  else
    ((success_count++))
  fi
done

end_time=$(date +%s); elapsed=$((end_time-start_time)); minutes=$((elapsed/60)); seconds=$((elapsed%60))

echo
echo "===== 极速截图完成 ====="
echo "成功: ${success_count} 张 | 失败: ${fail_count} 张"
echo "总耗时: ${minutes}分${seconds}秒"
echo "输出格式: JPG (无字幕处理)"

if [ $fail_count -gt 0 ]; then
  echo; echo "===== 失败详情 ====="
  for i in "${!failed_files[@]}"; do
    echo "[失败] 文件: ${failed_files[$i]}"; echo "原因: ${failed_reasons[$i]}"; echo
  done
fi
