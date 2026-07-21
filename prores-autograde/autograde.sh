#!/usr/bin/env bash
#
# autograde.sh — ProRes 素材を自動グレーディング（色補正）して ProRes で一括書き出し
#
#   ハードディスク上の ProRes 動画を、フォルダごと自動で色補正し、
#   編集向きの ProRes ファイルとして書き出します。ローカル実行前提（ffmpeg 必須）。
#
# 使い方:
#   ./autograde.sh [オプション] <入力ディレクトリ or ファイル> [さらに...]
#
# 主なオプション:
#   -o, --output DIR      出力先ディレクトリ            (既定: ./graded)
#   -p, --profile NAME    ProRes profile               (既定: hq)
#                           proxy | lt | standard | hq | 4444 | 4444xq | same
#   -r, --res SIZE        出力解像度                    (既定: source)
#                           source | 4k | 1080p | 720p
#   -s, --strength N      自動補正の強さ 0.0〜1.0        (既定: 0.7)
#       --sharpen         軽いシャープをかける
#       --no-normalize    自動レベル/ホワイトバランスを無効化
#       --lut FILE.cube   .cube LUT を追加適用（自動補正の後段に乗る）
#   -j, --jobs N          並列処理数                    (既定: 1)
#   -n, --dry-run         コマンドを表示するだけで実行しない
#   -y, --overwrite       既存の出力を上書き
#   -h, --help            このヘルプ
#
# 例:
#   ./autograde.sh /Volumes/HDD/footage
#   ./autograde.sh -r 1080p -o ~/graded /Volumes/HDD/footage
#   ./autograde.sh --lut mylook.cube -s 0.5 clip1.mov clip2.mov
#
set -euo pipefail

# ---------- 既定値 ----------
OUTPUT_DIR="./graded"
PROFILE="hq"
RES="source"
STRENGTH="0.7"
SHARPEN=0
NORMALIZE=1
LUT=""
JOBS=1
DRY_RUN=0
OVERWRITE=0
INPUTS=()

# ProRes を含む拡張子（大文字小文字は問わない）
VIDEO_EXTS=("mov" "mxf" "mp4" "mkv" "avi" "m4v")

# ---------- 色付きログ ----------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi
info()  { printf '%s\n' "${C_BLU}▶${C_RST} $*"; }
ok()    { printf '%s\n' "${C_GRN}✓${C_RST} $*"; }
warn()  { printf '%s\n' "${C_YEL}⚠${C_RST} $*" >&2; }
err()   { printf '%s\n' "${C_RED}✗${C_RST} $*" >&2; }
dim()   { printf '%s\n' "${C_DIM}$*${C_RST}"; }

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------- 引数パース ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)     OUTPUT_DIR="$2"; shift 2 ;;
    -p|--profile)    PROFILE="$2"; shift 2 ;;
    -r|--res)        RES="$2"; shift 2 ;;
    -s|--strength)   STRENGTH="$2"; shift 2 ;;
    --sharpen)       SHARPEN=1; shift ;;
    --no-normalize)  NORMALIZE=0; shift ;;
    --lut)           LUT="$2"; shift 2 ;;
    -j|--jobs)       JOBS="$2"; shift 2 ;;
    -n|--dry-run)    DRY_RUN=1; shift ;;
    -y|--overwrite)  OVERWRITE=1; shift ;;
    -h|--help)       usage 0 ;;
    --)              shift; while [[ $# -gt 0 ]]; do INPUTS+=("$1"); shift; done ;;
    -*)              err "不明なオプション: $1"; usage 1 ;;
    *)               INPUTS+=("$1"); shift ;;
  esac
done

# ---------- 依存チェック ----------
for bin in ffmpeg ffprobe; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    err "$bin が見つかりません。ffmpeg をインストールしてください。"
    dim "  macOS:  brew install ffmpeg"
    dim "  Ubuntu: sudo apt install ffmpeg"
    exit 1
  fi
done

if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'prores_ks'; then
  err "この ffmpeg には prores_ks エンコーダがありません。ProRes 対応ビルドが必要です。"
  exit 1
fi

if [[ ${#INPUTS[@]} -eq 0 ]]; then
  err "入力（ディレクトリ or ファイル）を指定してください。"
  usage 1
fi

# ---------- profile 名 → prores_ks profile 番号 ----------
# same は入力ごとに判定するため、ここでは -1 のプレースホルダにする
profile_num() {
  case "$1" in
    proxy)    echo 0 ;;
    lt)       echo 1 ;;
    standard) echo 2 ;;
    hq)       echo 3 ;;
    4444)     echo 4 ;;
    4444xq)   echo 5 ;;
    same)     echo -1 ;;
    *)        err "不明な profile: $1 (proxy|lt|standard|hq|4444|4444xq|same)"; exit 1 ;;
  esac
}
PROFILE_NUM="$(profile_num "$PROFILE")"

# 入力 ProRes の profile 名を推定（same 用）
detect_profile_num() {
  local f="$1" tag
  tag="$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_tag_string -of csv=p=0 "$f" 2>/dev/null || true)"
  case "$tag" in
    apco) echo 0 ;;  # proxy
    apcs) echo 1 ;;  # lt
    apcn) echo 2 ;;  # standard 422
    apch) echo 3 ;;  # 422 HQ
    ap4h) echo 4 ;;  # 4444
    ap4x) echo 5 ;;  # 4444 XQ
    *)    echo 3 ;;  # 不明なら 422 HQ にフォールバック
  esac
}

# profile 番号 → 適切な pix_fmt
pix_fmt_for() {
  case "$1" in
    4|5) echo "yuv444p10le" ;;   # 4444 系
    *)   echo "yuv422p10le" ;;
  esac
}

# ---------- 解像度 → scale フィルタ ----------
scale_filter() {
  case "$RES" in
    source) echo "" ;;
    4k)     echo "scale=-2:2160:flags=lanczos" ;;
    1080p)  echo "scale=-2:1080:flags=lanczos" ;;
    720p)   echo "scale=-2:720:flags=lanczos" ;;
    *)      err "不明な解像度: $RES (source|4k|1080p|720p)"; exit 1 ;;
  esac
}

# ---------- 自動グレーディングのフィルタチェーンを組み立て ----------
# STRENGTH に応じて補正量をスケールし、白飛び/黒潰れを避けた自然な仕上がりにする
build_vf() {
  local fps="$1" chain=()

  # 1) 自動レベル + ホワイトバランス（normalize）
  #    フレームごとに独立補正するとちらつくため smoothing で時間平滑化する
  if [[ "$NORMALIZE" -eq 1 ]]; then
    local smooth
    smooth="$(awk -v f="$fps" 'BEGIN{ s=int(f*0.75); if(s<8)s=8; if(s>90)s=90; print s }')"
    chain+=("normalize=smoothing=${smooth}:independence=0.6:strength=${STRENGTH}")
  fi

  # 2) 見栄えの微調整（コントラスト/彩度/ガンマ）を強さに比例させる
  local contrast saturation gamma
  contrast="$(awk -v s="$STRENGTH"   'BEGIN{ printf "%.4f", 1.0 + 0.10*s }')"
  saturation="$(awk -v s="$STRENGTH" 'BEGIN{ printf "%.4f", 1.0 + 0.16*s }')"
  gamma="$(awk -v s="$STRENGTH"      'BEGIN{ printf "%.4f", 1.0 + 0.03*s }')"
  chain+=("eq=contrast=${contrast}:saturation=${saturation}:gamma=${gamma}")

  # 3) 任意: LUT（.cube）を後段に適用
  if [[ -n "$LUT" ]]; then
    local lp; lp="$(printf '%s' "$LUT" | sed "s/:/\\\\:/g")"
    chain+=("lut3d=file='${lp}'")
  fi

  # 4) 任意: 軽いシャープ
  if [[ "$SHARPEN" -eq 1 ]]; then
    chain+=("unsharp=5:5:0.6:5:5:0.0")
  fi

  # 5) 解像度変更（指定時のみ）
  local sf; sf="$(scale_filter)"
  [[ -n "$sf" ]] && chain+=("$sf")

  local IFS=,
  echo "${chain[*]}"
}

# ---------- 入力ファイルの収集 ----------
is_video() {
  local ext="${1##*.}"; ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  local e; for e in "${VIDEO_EXTS[@]}"; do [[ "$ext" == "$e" ]] && return 0; done
  return 1
}

FILES=()
for inp in "${INPUTS[@]}"; do
  if [[ -d "$inp" ]]; then
    while IFS= read -r -d '' f; do FILES+=("$f"); done \
      < <(find "$inp" -type f -print0 | sort -z)
  elif [[ -f "$inp" ]]; then
    FILES+=("$inp")
  else
    warn "見つかりません: $inp"
  fi
done

# 動画のみに絞り込み
VIDEO_FILES=()
for f in "${FILES[@]}"; do is_video "$f" && VIDEO_FILES+=("$f"); done

if [[ ${#VIDEO_FILES[@]} -eq 0 ]]; then
  err "処理対象の動画が見つかりませんでした（対象拡張子: ${VIDEO_EXTS[*]}）。"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

info "対象 ${#VIDEO_FILES[@]} ファイル / profile=${PROFILE} / res=${RES} / strength=${STRENGTH}"
[[ -n "$LUT" ]] && info "LUT: $LUT"
[[ "$DRY_RUN" -eq 1 ]] && warn "ドライラン: 実際の書き出しは行いません"
echo

# ---------- 1 ファイル処理 ----------
process_one() {
  local in="$1"
  local base; base="$(basename "$in")"
  local stem="${base%.*}"
  local out="${OUTPUT_DIR%/}/${stem}_graded.mov"

  if [[ -e "$out" && "$OVERWRITE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    warn "スキップ（既に存在）: $out"
    return 0
  fi

  # fps を取得（フィルタの平滑化フレーム数に使用）
  local fps_raw fps
  fps_raw="$(ffprobe -v error -select_streams v:0 \
             -show_entries stream=r_frame_rate -of csv=p=0 "$in" 2>/dev/null || echo "30/1")"
  fps="$(awk -F/ 'BEGIN{v=30} { if ($2>0) v=$1/$2; else v=$1 } END{ printf "%.3f", v }' <<<"$fps_raw")"

  # profile 番号の決定（same の場合は入力から判定）
  local pnum="$PROFILE_NUM"
  [[ "$pnum" -lt 0 ]] && pnum="$(detect_profile_num "$in")"
  local pix; pix="$(pix_fmt_for "$pnum")"

  local vf; vf="$(build_vf "$fps")"

  local -a cmd=(
    ffmpeg -hide_banner -y
    -i "$in"
    -vf "$vf"
    -map 0:v:0 -map "0:a?"
    -c:v prores_ks -profile:v "$pnum" -pix_fmt "$pix" -vendor apl0
    -c:a copy
    -map_metadata 0 -movflags +write_colr
    "$out"
  )

  dim "  in : $in"
  dim "  out: $out  (prores profile=$pnum, pix=$pix, ${fps}fps)"
  dim "  vf : $vf"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '   '; printf '%q ' "${cmd[@]}"; echo
    return 0
  fi

  if "${cmd[@]}" </dev/null >/dev/null 2>"${out}.log"; then
    rm -f "${out}.log"
    ok "完了: $out"
  else
    err "失敗: $in  （ログ: ${out}.log）"
    return 1
  fi
}
export -f process_one info ok warn err dim build_vf scale_filter pix_fmt_for detect_profile_num
export OUTPUT_DIR PROFILE PROFILE_NUM RES STRENGTH SHARPEN NORMALIZE LUT DRY_RUN OVERWRITE
export C_RED C_GRN C_YEL C_BLU C_DIM C_RST

# ---------- 実行（直列 or 並列） ----------
FAIL=0
if [[ "$JOBS" -gt 1 && "$DRY_RUN" -eq 0 ]] && command -v xargs >/dev/null 2>&1; then
  info "並列処理: ${JOBS} 本"
  printf '%s\0' "${VIDEO_FILES[@]}" \
    | xargs -0 -P "$JOBS" -I{} bash -c 'process_one "$@"' _ {} || FAIL=1
else
  for f in "${VIDEO_FILES[@]}"; do
    process_one "$f" || FAIL=1
  done
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  ok "すべて完了しました → ${OUTPUT_DIR}"
else
  warn "一部のファイルで失敗しました。ログ（*.log）を確認してください。"
  exit 1
fi
