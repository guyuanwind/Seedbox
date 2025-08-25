#!/bin/bash
# 批量截图（目录智能识别 + 就近对齐“必有字幕”）
# - 输入：视频文件 / ISO / 目录
#   · 目录：先找 ISO(最大)→挂载→最大 .m2ts；否则找 BDMV/STREAM；否则找常见视频
#     - 多视频时优先选择文件名包含 E01 的（不区分大小写；如多个取体积最大）；否则取体积最大
# - 时间点：提供则就近对齐；未提供则自动取 20%/40%/60%/80% 并对齐
# - 字幕优先：中文 → 英文 → 其他/无；无中文但有英文会提示；无字幕则只截画面并提示
# - 位图字幕(如 PGS) overlay；文本字幕(ASS/SRT) subtitles（使用系统默认字体）
# - 双段 seek：PGS 预滚 12s，文本 3s；>10MB 自动 SDR 重拍；trap 清理 ISO 挂载
# 用法：
#   ./screenshots.sh <视频/ISO/目录> <输出目录> [HH:MM:SS|MM:SS] [...]

set -u
log(){ echo -e "$*" >&2; }

FIRST_RUN=0
success_count=0
fail_count=0
failed_files=()
failed_reasons=()

time_regex='^([0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}$'

# —— 探测与对齐参数
PROBESIZE="150M"
ANALYZE="150M"
COARSE_BACK_TEXT=3           # 文本字幕预滚动
COARSE_BACK_PGS=12           # PGS 预滚动
SEARCH_BACK=6
SEARCH_FWD=10
SUB_SNAP_EPS=0.50            # 边缘缓冲
DEFAULT_SUB_DUR=4.00
PGS_MIN_PKT=1500             # 视为有效 PGS 包的最小 size
AUTO_PERC=("0.20" "0.40" "0.60" "0.80")

MOUNTED=0
MOUNT_DIR=""
ISO_PATH=""
M2TS_INPUT=""
START_OFFSET="0.0"
DURATION="0.0"

SUB_MODE=""
SUB_FILE=""
SUB_SI=""
SUB_REL=""
SUB_LANG=""
SUB_CODEC=""
SUB_IDX=""

# —— 语言集合
LANGS_ZH=("zh" "zho" "chi" "zh-cn" "zh_cn" "chs" "cht" "cn" "chinese" "mandarin" "cantonese" "yue" "han")
LANGS_EN=("en" "eng" "english")

lower(){ echo "$1" | tr '[:upper:]' '[:lower:]'; }
has_lang_token(){
  local lang="$(lower "$1")"; shift
  for t in "$@"; do
    t="$(lower "$t")"
    [[ "$lang" == *"$t"* ]] && return 0
  done
  return 1
}
escape_squote(){ echo "${1//\'/\\\'}"; }
is_iso(){ [[ "${1,,}" == *.iso ]]; }
hms_to_seconds(){ local t="$1" h=0 m=0 s=0; IFS=':' read -r a b c <<<"$t"; if [ -z "${c:-}" ]; then m=$a; s=$b; else h=$a; m=$b; s=$c; fi; echo $((10#$h*3600 + 10#$m*60 + 10#$s)); }
sec_to_hms(){ local x=${1%.*}; printf "%02d:%02d:%02d" $((x/3600)) $(((x%3600)/60)) $((x%60)); }
fmax(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f",(a>b?a:b)}'; }
fmin(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f",(a<b?a:b)}'; }
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
  [ -n "${SUB_IDX:-}" ] && [ -f "$SUB_IDX" ] && rm -f "$SUB_IDX"
}
trap 'cleanup' EXIT INT TERM

# —— 依赖
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
check_and_install_jq(){
  if ! command -v jq >/dev/null 2>&1; then
    log "[依赖检测] 缺少 jq，正在安装..."
    sudo apt update -y && sudo apt install -y jq || { log "[错误] 安装 jq 失败"; exit 1; }
    FIRST_RUN=1
  fi
}

validate_arguments(){
  # 检查是否提供了第一个和第二个参数
  if [ "$#" -lt 2 ]; then
    echo "[错误] 参数缺失：必须提供视频文件/ISO/目录和截图输出目录。"
    echo "正确用法: $0 <视频/ISO/目录> <输出目录> [时间点...]"
    exit 1
  fi

  # 获取第一个参数和输出目录
  local p="$1" outdir="$2"
  
  # 检查输入的路径是否有效
  if [ ! -f "$p" ] && [ ! -d "$p" ]; then
    echo "[错误] 视频文件或目录不存在：$p"
    echo "正确用法: $0 <视频/ISO/目录> <输出目录> [时间点...]"
    exit 1
  fi

  # 确认第二个参数（输出目录）存在且是一个有效的目录
  if [ -z "$outdir" ]; then
    echo "[错误] 参数缺失：必须提供截图输出目录。"
    echo "正确用法: $0 <视频/ISO/目录> <输出目录> [时间点...]"
    exit 1
  fi

  # 如果输出目录不存在，则创建
  if [ ! -d "$outdir" ]; then
    log "[提示] 输出目录不存在，正在创建：$outdir"
    mkdir -p "$outdir" || { log "[错误] 创建输出目录失败：$outdir"; exit 1; }
  fi

  shift 2
  # 检查时间点格式
  for t in "$@"; do
    if [[ ! "$t" =~ ^([0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}$ ]]; then
      echo "[错误] 时间点格式不正确：$t"
      echo "正确格式: 00:30:00 或 30:00"
      exit 1
    fi
  done
}



# —— ISO & m2ts
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

# —— 目录选择逻辑
select_input_from_arg(){
  local input="$1"
  if [ -d "$input" ]; then
    log "[提示] 输入为目录，开始智能识别..."
    # 1) ISO（同层，取最大）
    local iso
    iso=$(find "$input" -maxdepth 1 -type f -iname '*.iso' -printf '%s %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
    if [ -n "$iso" ]; then
      mount_iso "$iso"
      find_largest_m2ts "$MOUNT_DIR" || { echo "[错误] ISO 内无 .m2ts"; exit 1; }
      video="$M2TS_INPUT"
      log "[信息] 将使用 m2ts 文件：$video"
      return 0
    fi
    # 2) BDMV/STREAM
    if [ -d "$input/BDMV/STREAM" ]; then
      find_largest_m2ts_in_dir "$input" || { echo "[错误] 目录内无 .m2ts"; exit 1; }
      video="$M2TS_INPUT"
      log "[信息] 将使用 m2ts 文件：$video"
      return 0
    fi
    # 3) 常见视频（同层）
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
    # 多个：优先 E01
    local -a e01=()
    for f in "${vids[@]}"; do
      if echo "${f##*/}" | grep -qiE '(^|[^0-9])e01([^0-9]|$)'; then e01+=("$f"); fi
    done
    if [ ${#e01[@]} -gt 0 ]; then
      local largest="" max=0 sz
      for f in "${e01[@]}"; do
        sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if [ "$sz" -gt "$max" ]; then max=$sz; largest="$f"; fi
      done
      video="$largest"
      log "[信息] 多个视频，优先选择包含 E01 的：$video"
      return 0
    fi
    # fallback：体积最大
    local biggest
    biggest=$(printf '%s\0' "${vids[@]}" | xargs -0 -I{} stat -c '%s %n' "{}" | sort -nr | head -1 | cut -d' ' -f2-)
    video="$biggest"
    log "[提示] 多个视频但未发现 E01，改选体积最大：$video"
    return 0
  elif is_iso "$input"; then
    mount_iso "$input"
    find_largest_m2ts "$MOUNT_DIR" || { echo "[错误] ISO 内无 .m2ts"; exit 1; }
    video="$M2TS_INPUT"
    log "[信息] 将使用 m2ts 文件：$video"
    return 0
  elif [ -f "$input" ]; then
    video="$input"
    return 0
  else
    echo "[错误] 无法识别输入路径：$input"; exit 1
  fi
}

# —— 字幕选择
find_external_sub(){
  local vpath="$1" dir base
  dir="$(cd "$(dirname "$vpath")" && pwd)"
  base="$(basename "$vpath")"
  base="${base%.*}"

  local cands=()
  for ext in ass srt; do
    for z in "${LANGS_ZH[@]}"; do cands+=("$dir/${base}.$z.$ext" "$dir/${base}-${z}.$ext" "$dir/${base}_$z.$ext"); done
    for e in "${LANGS_EN[@]}"; do cands+=("$dir/${base}.$e.$ext" "$dir/${base}-${e}.$ext" "$dir/${base}_$e.$ext"); done
    cands+=("$dir/${base}.$ext")
  done
  while IFS= read -r -d '' f; do cands+=("$f"); done < <(find "$dir" -maxdepth 1 -type f \( -iname "*.ass" -o -iname "*.srt" \) -iname "*${base}*" -print0)

  declare -A seen
  local best="" score best_score=-1
  for f in "${cands[@]}"; do
    [ -f "$f" ] || continue
    [ -n "${seen[$f]:-}" ] && continue
    seen[$f]=1
    score=0
    local fn="${f##*/}"
    has_lang_token "$fn" "${LANGS_ZH[@]}" && score=100
    has_lang_token "$fn" "${LANGS_EN[@]}" && score=$((score>0?score:50))
    score=$((score+1))
    [ $score -gt $best_score ] && { best_score=$score; best="$f"; }
  done

  if [ -n "$best" ]; then
    SUB_MODE="external"; SUB_FILE="$best"
    if has_lang_token "$best" "${LANGS_ZH[@]}"; then
      SUB_LANG="zh"
    elif has_lang_token "$best" "${LANGS_EN[@]}"; then
      SUB_LANG="en"
    else
      SUB_LANG="unknown"
    fi
    SUB_CODEC="text"
    log "[信息] 选择外挂字幕：$SUB_FILE （语言：$SUB_LANG）"
    return 0
  fi
  return 1
}

pick_internal_sub(){
  local vpath="$1" j parsed
  j=$(ffprobe -probesize "$PROBESIZE" -analyzeduration "$ANALYZE" -v error \
      -select_streams s \
      -show_entries stream=index,codec_name,disposition:stream_tags=language \
      -of json "$vpath" 2>/dev/null) || true
  [ -z "$j" ] && return 1

  parsed=$(echo "$j" | jq -r '.streams[] | [
      .index,
      (.codec_name // "" | ascii_downcase),
      (.tags.language // "unknown" | ascii_downcase),
      (.disposition.forced // 0)
    ] | @tsv' 2>/dev/null) || true
  [ -z "$parsed" ] && return 1

  local best_idx="" best_codec="" best_lang_raw="" best_forced=""

  # 针对 PGS 字幕流的改进：如果 codec_name 是 "hdmv_pgs_subtitle"，则手动识别中文
  pick_by_langset(){
    local want_forced="$1" want_lang="$2" idx codec lang forced
    while IFS=$'\t' read -r idx codec lang forced; do
      [ -z "${idx:-}" ] && continue
      # 如果是 PGS 字幕且语言为中文（根据流名判断）
      if [[ "$codec" == "hdmv_pgs_subtitle" ]] && has_lang_token "$lang" "chinese"; then
        best_idx="$idx"; best_codec="$codec"; best_lang_raw="zh"; best_forced="$forced"; return 0
      fi
      # 优先选中文字幕
      if [ "$want_lang" = "zh" ]; then
        has_lang_token "$lang" "${LANGS_ZH[@]}" && [ "$forced" = "$want_forced" ] && {
          best_idx="$idx"; best_codec="$codec"; best_lang_raw="$lang"; best_forced="$forced"; return 0; }
      else
        has_lang_token "$lang" "${LANGS_EN[@]}" && [ "$forced" = "$want_forced" ] && {
          best_idx="$idx"; best_codec="$codec"; best_lang_raw="$lang"; best_forced="$forced"; return 0; }
      fi
    done <<< "$parsed"
    return 1
  }

  pick_by_langset "0" "zh" || pick_by_langset "1" "zh" || {
    pick_by_langset "0" "en" || pick_by_langset "1" "en" || true
  }

  if [ -z "$best_idx" ]; then
    best_idx=$(echo "$parsed" | head -n1 | awk -F'\t' '{print $1}')
    best_codec=$(echo "$parsed" | head -n1 | awk -F'\t' '{print $2}')
    best_lang_raw=$(echo "$parsed" | head -n1 | awk -F'\t' '{print $3}')
    best_forced=$(echo "$parsed" | head -n1 | awk -F'\t' '{print $4}')
  fi

  [ -n "$best_idx" ] || return 1

  if has_lang_token "$best_lang_raw" "${LANGS_ZH[@]}"; then SUB_LANG="zh"
  elif has_lang_token "$best_lang_raw" "${LANGS_EN[@]}"; then SUB_LANG="en"
  else SUB_LANG="unknown"; fi

  SUB_MODE="internal"; SUB_SI="$best_idx"; SUB_CODEC="$best_codec"
  log "[信息] 选择内挂字幕：流索引 $SUB_SI （语言：$SUB_LANG，forced=$best_forced，codec：$SUB_CODEC）"

  local rel=0 gi
  while IFS= read -r gi; do
    [ -z "$gi" ] && continue
    if [ "$gi" = "$SUB_SI" ]; then SUB_REL="$rel"; break; fi
    rel=$((rel+1))
  done < <(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$vpath" 2>/dev/null)
  [ -z "$SUB_REL" ] && SUB_REL="0"
  return 0
}


choose_subtitle(){
  local v="$1"
  SUB_MODE="none"; SUB_FILE=""; SUB_SI=""; SUB_REL=""; SUB_LANG=""; SUB_CODEC=""
  if find_external_sub "$v"; then
    [ "$SUB_LANG" = "en" ] && log "[提示] 未找到中文字幕，改用英文外挂字幕。"
    return 0
  fi
  if pick_internal_sub "$v"; then
    [ "$SUB_LANG" = "en" ] && log "[提示] 未找到中文字幕，改用英文内挂字幕。"
    return 0
  fi
  log "[提示] 未找到可用字幕，将仅截图视频画面。"
  return 1
}


is_bitmap_sub(){
  case "$(lower "${SUB_CODEC:-}")" in
    hdmv_pgs_subtitle|pgssub|dvd_subtitle|dvb_subtitle|xsub|vobsub) return 0 ;;
    *) return 1 ;;
  esac
}
build_text_sub_filter(){
  # 使用系统默认字体，不额外指定 fontsdir/FontName，最大化兼容性
  if [ "$SUB_MODE" = "external" ]; then
    echo "subtitles='$(escape_squote "$SUB_FILE")'"
  elif [ "$SUB_MODE" = "internal" ]; then
    echo "subtitles='$(escape_squote "$video"):si=${SUB_SI}'"
  else
    echo ""
  fi
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

# —— PGS 事件（packet-size 过滤）
pgs_probe_events_internal_window_packets(){
  local start_abs="$1" dur="$2"
  ffprobe -v error -select_streams s:"$SUB_REL" -read_intervals "${start_abs}%+${dur}" \
    -show_packets -show_entries packet=pts_time,duration_time,size \
    -of default=noprint_wrappers=1 "$video" 2>/dev/null
}
packets_to_index_rel(){
  local mode="$1"
  awk -v defdur="$DEFAULT_SUB_DUR" -v off="$START_OFFSET" -v mode="$mode" -v minsz="$PGS_MIN_PKT" '
    /^pts_time=/ {pts=substr($0,index($0,"=")+1)}
    /^duration_time=/ {dur=substr($0,index($0,"=")+1)}
    /^size=/ {sz=substr($0,index($0,"=")+1)
      if (pts!="") {
        if (dur=="" || dur=="N/A") dur=defdur
        if (sz+0 >= minsz) {
          s=pts; e=pts+dur
          if(mode=="internal"){ s-=off; e-=off }
          if(e<0){ pts=""; dur=""; next }
          if(s<0) s=0
          printf "%.6f %.6f\n", s, e
        }
        pts=""; dur=""
      }
    }'
}

# —— 文本字幕事件
probe_sub_events_internal_window(){
  local start_abs="$1" dur="$2"
  ffprobe -v error -select_streams s:"$SUB_REL" -read_intervals "${start_abs}%+${dur}" \
    -show_frames -show_entries frame=pkt_pts_time,pkt_duration_time -of default=noprint_wrappers=1 "$video" 2>/dev/null
}
probe_sub_events_external_window(){
  local start="$1" dur="$2"
  ffprobe -v error -read_intervals "${start}%+${dur}" \
    -show_frames -show_entries frame=pkt_pts_time,pkt_duration_time -of default=noprint_wrappers=1 "$SUB_FILE" 2>/dev/null
}
dump_all_sub_events_internal(){
  ffprobe -v error -select_streams s:"$SUB_REL" \
    -show_frames -show_entries frame=pkt_pts_time,pkt_duration_time -of default=noprint_wrappers=1 "$video" 2>/dev/null
}
dump_all_sub_events_external(){
  ffprobe -v error -show_frames -show_entries frame=pkt_pts_time,pkt_duration_time -of default=noprint_wrappers=1 "$SUB_FILE" 2>/dev/null
}
frames_to_index_rel(){
  local mode="$1"
  awk -v defdur="$DEFAULT_SUB_DUR" -v off="$START_OFFSET" -v mode="$mode" '
    /^pkt_pts_time=/ {pts=substr($0,index($0,"=")+1)}
    /^pkt_duration_time=/ {
      dur=substr($0,index($0,"=")+1)
      if (dur=="" || dur=="N/A") dur=defdur
      if (pts!="") {
        s=pts; e=pts+dur
        if(mode=="internal"){ s-=off; e-=off }
        if(e<0) next
        if(s<0) s=0
        printf "%.6f %.6f\n", s, e
        pts=""; dur=""
      }
    }
    END {
      if (pts!="") {
        s=pts; e=pts+defdur
        if(mode=="internal"){ s-=off; e-=off }
        if(e>=0){
          if(s<0) s=0
          printf "%.6f %.6f\n", s, e
        }
      }
    }'
}

# —— 就近对齐
pgs_nearest_expand(){
  local T="$1"
  local spans=(60 120 240 480 900)
  local best_t="" best_dist=1e18
  local Tabs win_s win_d out mid dist s e
  for sp in "${spans[@]}"; do
    Tabs=$(fadd "$T" "$START_OFFSET")
    win_s=$(fsub "$Tabs" "$sp"); win_s=$(awk -v v="$win_s" 'BEGIN{print (v<0?0:v)}')
    win_d=$(fadd "$sp" "$sp")
    out=$(pgs_probe_events_internal_window_packets "$win_s" "$win_d" | packets_to_index_rel internal)
    [ -z "$out" ] && continue
    while read -r s e; do
      [ -z "$s" ] && continue
      mid=$(awk -v s="$s" -v e="$e" 'BEGIN{printf "%.6f", s+(e-s)/2}')
      dist=$(awk -v a="$mid" -v b="$T" 'BEGIN{d=a-b; if(d<0)d=-d; printf "%.6f", d}')
      awk -v d="$dist" -v bd="$best_dist" 'BEGIN{exit !(d<bd)}' && { best_dist="$dist"; best_t="$mid"; }
    done <<< "$out"
    [ -n "$best_t" ] && break
  done
  if [ -n "$best_t" ]; then echo "$(clamp_0_dur "$best_t")"; else echo "$T"; fi
}

snap_window(){
  local T="$1" eps="$SUB_SNAP_EPS" win_s win_d
  [ "$SUB_MODE" = "none" ] && { echo "$T"; return 0; }

  if [ "$SUB_MODE" = "internal" ]; then
    if is_bitmap_sub; then
      local Tabs; Tabs=$(fadd "$T" "$START_OFFSET")
      win_s=$(fsub "$Tabs" "$SEARCH_BACK"); win_s=$(awk -v v="$win_s" 'BEGIN{print (v<0?0:v)}')
      win_d=$(fadd "$SEARCH_BACK" "$SEARCH_FWD")
      pgs_probe_events_internal_window_packets "$win_s" "$win_d" | packets_to_index_rel internal | \
      awk -v T="$T" -v eps="$eps" '
        { s=$1; e=$2;
          if (T>=s && T<=e){ c=T; if(c<s+eps)c=s+eps; if(c>e-eps)c=e-eps; printf "%.6f\n", c; exit }
          if (!p && s>=T){ printf "%.6f\n", s+eps; p=1; exit }
        }'
    else
      local Tabs; Tabs=$(fadd "$T" "$START_OFFSET")
      win_s=$(fsub "$Tabs" "$SEARCH_BACK"); win_s=$(awk -v v="$win_s" 'BEGIN{print (v<0?0:v)}')
      win_d=$(fadd "$SEARCH_BACK" "$SEARCH_FWD")
      probe_sub_events_internal_window "$win_s" "$win_d" | frames_to_index_rel internal | \
      awk -v T="$T" -v eps="$eps" '
        { s=$1; e=$2;
          if (T>=s && T<=e){ c=T; if(c<s+eps)c=s+eps; if(c>e-eps)c=e-eps; printf "%.6f\n", c; exit }
          if (!p && s>=T){ printf "%.6f\n", s+eps; p=1; exit }
        }'
    fi
  else
    win_s=$(fsub "$T" "$SEARCH_BACK"); win_s=$(awk -v v="$win_s" 'BEGIN{print (v<0?0:v)}')
    win_d=$(fadd "$SEARCH_BACK" "$SEARCH_FWD")
    probe_sub_events_external_window "$win_s" "$win_d" | frames_to_index_rel external | \
    awk -v T="$T" -v eps="$eps" '
      { s=$1; e=$2;
        if (T>=s && T<=e){ c=T; if(c<s+eps)c=s+eps; if(c>e-eps)c=e-eps; printf "%.6f\n", c; exit }
        if (!p && s>=T){ printf "%.6f\n", s+eps; p=1; exit }
      }'
  fi
}
snap_from_index(){
  local T="$1" eps="$SUB_SNAP_EPS"
  [ -n "$SUB_IDX" ] && [ -s "$SUB_IDX" ] || { echo "$T"; return 1; }
  awk -v T="$T" -v eps="$eps" '
    BEGIN{bestAfterS=-1; lastS=-1; lastE=-1;}
    { s=$1; e=$2;
      if (T>=s && T<=e){ c=T; if(c<s+eps)c=s+eps; if(c>e-eps)c=e-eps; printf "%.6f\n", c; found=1; exit }
      if (bestAfterS<0 && s>=T){ bestAfterS=s; bestAfterE=e }
      if (s<=T){ lastS=s; lastE=e }
    }
    END{
      if (!found){
        if (bestAfterS>=0) printf "%.6f\n", bestAfterS+eps;
        else if (lastS>=0) printf "%.6f\n", (lastE-eps>lastS? lastE-eps : lastS+eps);
        else printf "%.6f\n", T;
      }
    }' "$SUB_IDX"
}
align_to_subtitle(){
  local T="$1" cand=""
  [ "$SUB_MODE" = "none" ] && { echo "$T"; return 0; }

  cand="$(snap_window "$T")"
  if [ -n "${cand:-}" ]; then
    cand="$(clamp_0_dur "$cand")"
    log "[对齐] 请求 $(sec_to_hms ${T%.*}) → 就近/扩窗字幕 $(sec_to_hms ${cand%.*})"
    echo "$cand"; return 0
  fi

  if [ "$SUB_MODE" = "internal" ]; then
    local Tabs win_s win_d
    Tabs=$(fadd "$T" "$START_OFFSET")
    win_s=$(fsub "$Tabs" 60); win_s=$(awk -v v="$win_s" 'BEGIN{print (v<0?0:v)}')
    win_d=120
    if is_bitmap_sub; then
      cand=$(pgs_probe_events_internal_window_packets "$win_s" "$win_d" | packets_to_index_rel internal | \
        awk -v T="$T" -v eps="$SUB_SNAP_EPS" '
          { s=$1; e=$2;
            if (T>=s && T<=e){ c=T; if(c<s+eps)c=s+eps; if(c>e-eps)c=e-eps; printf "%.6f\n", c; exit }
            if (!p && s>=T){ printf "%.6f\n", s+eps; p=1; exit }
          }')
    else
      cand=$(probe_sub_events_internal_window "$win_s" "$win_d" | frames_to_index_rel internal | \
        awk -v T="$T" -v eps="$SUB_SNAP_EPS" '
          { s=$1; e=$2;
            if (T>=s && T<=e){ c=T; if(c<s+eps)c=s+eps; if(c>e-eps)c=e-eps; printf "%.6f\n", c; exit }
            if (!p && s>=T){ printf "%.6f\n", s+eps; p=1; exit }
          }')
    fi
  else
    local win_s win_d; win_s=$(fsub "$T" 60); win_s=$(awk -v v="$win_s" 'BEGIN{print (v<0?0:v)}'); win_d=120
    cand=$(probe_sub_events_external_window "$win_s" "$win_d" | frames_to_index_rel external | \
      awk -v T="$T" -v eps="$SUB_SNAP_EPS" '
        { s=$1; e=$2;
          if (T>=s && T<=e){ c=T; if(c<s+eps)c=s+eps; if(c>e-eps)c=e-eps; printf "%.6f\n", c; exit }
          if (!p && s>=T){ printf "%.6f\n", s+eps; p=1; exit }
        }')
  fi
  if [ -n "${cand:-}" ]; then
    cand="$(clamp_0_dur "$cand")"
    log "[对齐] 请求 $(sec_to_hms ${T%.*}) → 扩窗字幕 $(sec_to_hms ${cand%.*})"
    echo "$cand"; return 0
  fi

  if [ "$SUB_MODE" = "internal" ] && is_bitmap_sub; then
    cand="$(pgs_nearest_expand "$T")"
    if [ -n "${cand:-}" ] && awk -v a="$cand" -v b="$T" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=1200)}'; then
      cand="$(clamp_0_dur "$cand")"
      log "[对齐] 请求 $(sec_to_hms ${T%.*}) → 渐进扩窗 $(sec_to_hms ${cand%.*})"
      echo "$cand"; return 0
    fi
  fi

  [ -z "${SUB_IDX:-}" ] && build_sub_index >/dev/null 2>&1 || true
  cand="$(snap_from_index "$T")"
  cand="$(clamp_0_dur "$cand")"
  if [ "$cand" != "$T" ]; then
    log "[对齐] 请求 $(sec_to_hms ${T%.*}) → 全片索引 $(sec_to_hms ${cand%.*})"
  else
    log "[提示] 周边及全片均未找到字幕事件，按原时间点截图：$(sec_to_hms ${T%.*})"
  fi
  echo "$cand"
}

build_sub_index(){
  if [ "$SUB_MODE" = "none" ] || is_bitmap_sub; then
    SUB_IDX=""; return 1
  fi
  SUB_IDX="$(mktemp -t subidx.XXXXXX)"
  if [ "$SUB_MODE" = "internal" ]; then
    dump_all_sub_events_internal | frames_to_index_rel internal | sort -n -k1,1 > "$SUB_IDX"
  else
    dump_all_sub_events_external | frames_to_index_rel external | sort -n -k1,1 > "$SUB_IDX"
  fi
  [ -s "$SUB_IDX" ] && { log "[信息] 已建立字幕索引（文字字幕）。"; return 0; }
  rm -f "$SUB_IDX"; SUB_IDX=""; return 1
}

# —— 截图
do_screenshot(){
  local t_aligned="$1" path="$2" err
  local tnum="${t_aligned%.*}"; [[ "$tnum" =~ ^[0-9]+$ ]] || tnum=0
  local coarse_sec
  if [ "$SUB_MODE" = "internal" ] && is_bitmap_sub; then
    coarse_sec=$(( tnum > COARSE_BACK_PGS ? tnum - COARSE_BACK_PGS : 0 ))
  else
    coarse_sec=$(( tnum > COARSE_BACK_TEXT ? tnum - COARSE_BACK_TEXT : 0 ))
  fi
  local fine_sec="$(fsub "$t_aligned" "$coarse_sec")"
  local coarse_hms="$(sec_to_hms "$coarse_sec")"

  if [ "$SUB_MODE" = "internal" ] && is_bitmap_sub; then
    err=$(ffmpeg -v error -fflags +genpts -ss "$coarse_hms" -probesize "$PROBESIZE" -analyzeduration "$ANALYZE" \
      -i "$video" -ss "$fine_sec" \
      -filter_complex "[0:v:0][0:s:${SUB_REL}]overlay=(W-w)/2:(H-h-10)" \
      -frames:v 1 -y "$path" 2>&1)
  else
    local subf; subf="$(build_text_sub_filter)"
    if [ -n "$subf" ]; then
      err=$(ffmpeg -v error -fflags +genpts -ss "$coarse_hms" -probesize "$PROBESIZE" -analyzeduration "$ANALYZE" \
        -i "$video" -ss "$fine_sec" -map 0:v:0 -y -frames:v 1 -vf "$subf,overlay=(W-w)/2:(H-h-10)" "$path" 2>&1)
    else
      err=$(ffmpeg -v error -fflags +genpts -ss "$coarse_hms" -probesize "$PROBESIZE" -analyzeduration "$ANALYZE" \
        -i "$video" -ss "$fine_sec" -map 0:v:0 -y -frames:v 1 -vf "overlay=(W-w)/2:(H-h-10)" "$path" 2>&1)
    fi
  fi
  local ret=$?
  if [ $ret -ne 0 ]; then failed_files+=("$(basename "$path")"); failed_reasons+=("$err"); fi
  return $ret
}

do_screenshot_reencode(){
  local t_aligned="$1" path="$2" err
  local tnum="${t_aligned%.*}"; [[ "$tnum" =~ ^[0-9]+$ ]] || tnum=0
  local coarse_sec
  if [ "$SUB_MODE" = "internal" ] && is_bitmap_sub; then
    coarse_sec=$(( tnum > COARSE_BACK_PGS ? tnum - COARSE_BACK_PGS : 0 ))
  else
    coarse_sec=$(( tnum > COARSE_BACK_TEXT ? tnum - COARSE_BACK_TEXT : 0 ))
  fi
  local fine_sec="$(fsub "$t_aligned" "$coarse_sec")"
  local coarse_hms="$(sec_to_hms "$coarse_sec")"

  if [ "$SUB_MODE" = "internal" ] && is_bitmap_sub; then
    err=$(ffmpeg -v error -fflags +genpts -ss "$coarse_hms" -probesize "$PROBESIZE" -analyzeduration "$ANALYZE" \
      -i "$video" -ss "$fine_sec" \
      -filter_complex "[0:v:0][0:s:${SUB_REL}]overlay=(W-w)/2:(H-h-10),format=gbrpf32le,zscale=pin=bt2020:p=bt709:t=linear:npl=100,tonemap=hable:desat=0:peak=5,format=rgb24" \
      -frames:v 1 -y -c:v png -compression_level 9 -pred mixed "$path" 2>&1)
  else
    local subf; subf="$(build_text_sub_filter)"
    local vf_chain="overlay=(W-w)/2:(H-h-10),format=gbrpf32le,zscale=pin=bt2020:p=bt709:t=linear:npl=100,tonemap=hable:desat=0:peak=5,format=rgb24"
    if [ -n "$subf" ]; then
      vf_chain="$subf,$vf_chain"
    fi
    err=$(ffmpeg -v error -fflags +genpts -ss "$coarse_hms" -probesize "$PROBESIZE" -analyzeduration "$ANALYZE" \
      -i "$video" -ss "$fine_sec" -map 0:v:0 -frames:v 1 -y -vf "$vf_chain" \
      -c:v png -compression_level 9 -pred mixed "$path" 2>&1)
  fi
  local ret=$?
  if [ $ret -ne 0 ]; then failed_files+=("$(basename "$path")"); failed_reasons+=("$err"); fi
  return $ret
}


# ---------------- 主流程 ----------------
check_and_install_bc
check_and_install_ffmpeg
check_and_install_jq
[ $FIRST_RUN -eq 1 ] && { log "[提示] 首次运行依赖安装完成。"; log ""; }

validate_arguments "$@"

input_path="$1"; outdir="$2"; shift 2

# 根据输入选择实际视频文件（可能挂载 ISO）
video=""
select_input_from_arg "$input_path"

# 字幕选择与时长检测
choose_subtitle "$video" || true
detect_start_offset
detect_duration
DURATION_HMS="$(sec_to_hms ${DURATION%.*})"
log "[信息] 容器起始偏移：${START_OFFSET}s | 影片总时长：${DURATION_HMS}"

log "[信息] 清空截图目录: $outdir"
rm -rf "${outdir:?}"/*

declare -a TARGET_SECONDS=()
if [ "$#" -gt 0 ]; then
  log "[信息] 已提供时间点：将对齐到附近有字幕后再截图"
  for tp in "$@"; do TARGET_SECONDS+=( "$(hms_to_seconds "$tp")" ); done
else
  log "[信息] 未提供时间点：自动按 20% / 40% / 60% / 80% 选取并确保有字幕"
  if awk -v d="$DURATION" 'BEGIN{exit !(d>0)}'; then
    for p in "${AUTO_PERC[@]}"; do
      t=$(awk -v d="$DURATION" -v p="$p" 'BEGIN{t=d*p; if(t<5)t=5; if(t>d-5)t=d-5; printf "%.3f",t}')
      TARGET_SECONDS+=( "$t" )
    done
  else
    log "[警告] 时长未知，退化为固定时间点：300/900/1800/2700 秒"
    TARGET_SECONDS=(300 900 1800 2700)
  fi
  build_sub_index >/dev/null 2>&1 || true
fi

start_time=$(date +%s)
idx=0
for T_req in "${TARGET_SECONDS[@]}"; do
  idx=$((idx+1))
  T_align="$(align_to_subtitle "$T_req" | tail -n1)"
  [ -z "$T_align" ] && T_align="$T_req"
  [ "${T_align:0:1}" = "." ] && T_align="0${T_align}"

  if [ "$#" -gt 0 ]; then
    minpart=$(( ${T_req%.*} / 60 ))
    filename="${minpart}min.png"
  else
    filename="auto${idx}.png"
  fi
  filepath="$outdir/$filename"

  log "[信息] 截图: $(sec_to_hms ${T_req%.*}) → 实际 $(sec_to_hms ${T_align%.*}) -> $filename"

  do_screenshot "$T_align" "$filepath"
  if [ $? -ne 0 ]; then ((fail_count++)); continue; fi

  size_bytes=$(stat -c%s "$filepath")
  size_mb=$(echo "scale=2; $size_bytes/1024/1024" | bc)
  if (( $(echo "$size_mb > 10" | bc -l) )); then
    log "[提示] $filename 大小 ${size_mb}MB，重拍并映射到 SDR..."
    do_screenshot_reencode "$T_align" "$filepath"
    [ $? -eq 0 ] && ((success_count++)) || ((fail_count++))
  else
    ((success_count++))
  fi
done

end_time=$(date +%s); elapsed=$((end_time-start_time)); minutes=$((elapsed/60)); seconds=$((elapsed%60))

echo
echo "===== 任务完成 ====="
echo "成功: ${success_count} 张 | 失败: ${fail_count} 张"
echo "总耗时: ${minutes}分${seconds}秒"

if [ $fail_count -gt 0 ]; then
  echo; echo "===== 失败详情 ====="
  for i in "${!failed_files[@]}"; do
    echo "[失败] 文件: ${failed_files[$i]}"; echo "原因: ${failed_reasons[$i]}"; echo
  done
fi
