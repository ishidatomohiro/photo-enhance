#!/usr/bin/env bash
#
# autograde.sh — ProRes 素材を自動グレーディング（色補正・クリーンアップ）して ProRes で書き出し
#
#   ライブ映像などの ProRes 素材を、色補正・ノイズ除去・モヤ取りまで含めて自動処理し、
#   編集向きの ProRes ファイルとして書き出します。ローカル実行前提（ffmpeg 必須）。
#
# 出力形式の自動判定 (--profile auto / 既定):
#   * 入力が ProRes    → 同じ profile に合わせる（LT なら LT、HQ なら HQ …）
#   * 入力が ProRes 以外 → 画質と容量のバランスが良い ProRes 422（standard）へ
#   解像度は既定で元のまま（4K なら 4K）。
#
# 使い方:
#   ./autograde.sh [オプション] <入力ディレクトリ or ファイル> [さらに...]
#
# 主なオプション:
#   -o, --output DIR      出力先ディレクトリ            (既定: ./graded)
#   -p, --profile NAME    auto | proxy | lt | standard | hq | 4444 | 4444xq | same
#                                                      (既定: auto)
#   -r, --res SIZE        source | 4k | 1080p | 720p    (既定: source)
#   -s, --strength N      自動補正の強さ 0.0〜1.0        (既定: 0.6)
#       --denoise MODE    off | light | medium | strong (既定: off)
#       --dehaze N        モヤ取り 0.0〜1.0              (既定: 0)
#       --sharpen         軽いシャープをかける
#       --no-normalize    自動レベル/ホワイトバランスを無効化
#       --lut FILE.cube   .cube LUT を後段に適用
#   -j, --jobs N          並列処理数                    (既定: 1)
#   -n, --dry-run         コマンドを表示するだけで実行しない
#   -y, --overwrite       既存の出力を上書き
#   -h, --help            このヘルプ
#
# 例:
#   ./autograde.sh /Volumes/HDD/live                       # 全自動（profile 自動判定）
#   ./autograde.sh --denoise medium --dehaze 0.4 live.mov  # 暗所ノイズ＋モヤのライブ素材
#   ./autograde.sh -p lt -r 1080p footage/                 # LT・1080p で軽く
#
set -euo pipefail

# ---------- 既定値 ----------
OUTPUT_DIR="./graded"
PROFILE="auto"
RES="source"
STRENGTH="0.6"
DENOISE="off"
DEHAZE="0"
SHARPEN=0
NORMALIZE=1
LUT=""
JOBS=1
DRY_RUN=0
OVERWRITE=0
INPUTS=()

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

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------- 引数パース ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)     OUTPUT_DIR="$2"; shift 2 ;;
    -p|--profile)    PROFILE="$2"; shift 2 ;;
    -r|--res)        RES="$2"; shift 2 ;;
    -s|--strength)   STRENGTH="$2"; shift 2 ;;
    --denoise)       DENOISE="$2"; shift 2 ;;
    --dehaze)        DEHAZE="$2"; shift 2 ;;
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
  err "入力（ディレクトリ or ファイル）を指定してください。"; usage 1
fi

# ---------- profile 名 → prores_ks profile 番号 ----------
#   auto = -2（ProRes は同 profile / それ以外は 422 standard）
#   same = -1（常に入力 ProRes と同じ profile）
profile_num() {
  case "$1" in
    auto)     echo -2 ;;
    same)     echo -1 ;;
    proxy)    echo 0 ;;
    lt)       echo 1 ;;
    standard) echo 2 ;;
    hq)       echo 3 ;;
    4444)     echo 4 ;;
    4444xq)   echo 5 ;;
    *) err "不明な profile: $1 (auto|proxy|lt|standard|hq|4444|4444xq|same)"; exit 1 ;;
  esac
}
PROFILE_NUM="$(profile_num "$PROFILE")"

codec_name_of() {
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of csv=p=0 "$1" 2>/dev/null || true
}
is_prores() { [[ "$(codec_name_of "$1")" == "prores" ]]; }

# 入力 ProRes の codec_tag → profile 番号
detect_profile_num() {
  local tag
  tag="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string \
        -of csv=p=0 "$1" 2>/dev/null || true)"
  case "$tag" in
    apco) echo 0 ;;  apcs) echo 1 ;;  apcn) echo 2 ;;
    apch) echo 3 ;;  ap4h) echo 4 ;;  ap4x) echo 5 ;;
    *)    echo 3 ;;  # 不明なら 422 HQ
  esac
}

pix_fmt_for() { case "$1" in 4|5) echo "yuv444p10le" ;; *) echo "yuv422p10le" ;; esac; }

# ---------- 解像度 → scale ----------
scale_filter() {
  case "$RES" in
    source) echo "" ;;
    4k)     echo "scale=-2:2160:flags=lanczos" ;;
    1080p)  echo "scale=-2:1080:flags=lanczos" ;;
    720p)   echo "scale=-2:720:flags=lanczos" ;;
    *)      err "不明な解像度: $RES (source|4k|1080p|720p)"; exit 1 ;;
  esac
}

# ---------- ノイズ除去モード → フィルタ ----------
denoise_filter() {
  case "$1" in
    off|"") echo "" ;;
    light)  echo "hqdn3d=2:1:3:3" ;;
    medium) echo "hqdn3d=4:3:6:6" ;;
    strong) echo "hqdn3d=8:6:9:9" ;;
    *) err "不明な denoise: $1 (off|light|medium|strong)"; exit 1 ;;
  esac
}

# ---------- 自動グレーディングのフィルタチェーン ----------
# 処理順: ノイズ除去 → 自動レベル → トーン → モヤ取り → LUT → シャープ → スケール
build_vf() {
  local fps="$1" chain=()

  # 1) ノイズ除去（シャープ/コントラスト前に置いてノイズを増幅させない）
  local df; df="$(denoise_filter "$DENOISE")"
  [[ -n "$df" ]] && chain+=("$df")

  # 2) 自動レベル + ホワイトバランス（時間平滑化でチラつき防止）
  if [[ "$NORMALIZE" -eq 1 ]]; then
    local smooth
    smooth="$(awk -v f="$fps" 'BEGIN{ s=int(f*0.75); if(s<8)s=8; if(s>90)s=90; print s }')"
    chain+=("normalize=smoothing=${smooth}:independence=0.6:strength=${STRENGTH}")
  fi

  # 3) トーンの微調整（強さに比例）
  local contrast saturation gamma
  contrast="$(awk -v s="$STRENGTH"   'BEGIN{ printf "%.4f", 1.0 + 0.10*s }')"
  saturation="$(awk -v s="$STRENGTH" 'BEGIN{ printf "%.4f", 1.0 + 0.16*s }')"
  gamma="$(awk -v s="$STRENGTH"      'BEGIN{ printf "%.4f", 1.0 + 0.03*s }')"
  chain+=("eq=contrast=${contrast}:saturation=${saturation}:gamma=${gamma}")

  # 4) モヤ取り（dehaze）: 大半径アンシャープ（局所コントラスト＝クラリティ）＋軽い追い込み
  if awk -v d="$DEHAZE" 'BEGIN{ exit !(d>0.001) }'; then
    local clarity dc dsat
    clarity="$(awk -v d="$DEHAZE" 'BEGIN{ printf "%.3f", 0.9*d }')"
    dc="$(awk -v d="$DEHAZE"      'BEGIN{ printf "%.4f", 1.0 + 0.14*d }')"
    dsat="$(awk -v d="$DEHAZE"    'BEGIN{ printf "%.4f", 1.0 + 0.08*d }')"
    chain+=("unsharp=9:9:${clarity}:9:9:0.0")
    chain+=("eq=contrast=${dc}:saturation=${dsat}")
  fi

  # 5) 任意: LUT
  if [[ -n "$LUT" ]]; then
    local lp; lp="$(printf '%s' "$LUT" | sed "s/:/\\\\:/g")"
    chain+=("lut3d=file='${lp}'")
  fi

  # 6) 任意: 仕上げのシャープ（細部）
  [[ "$SHARPEN" -eq 1 ]] && chain+=("unsharp=5:5:0.6:5:5:0.0")

  # 7) 解像度変更（指定時のみ）
  local sf; sf="$(scale_filter)"
  [[ -n "$sf" ]] && chain+=("$sf")

  local IFS=,
  echo "${chain[*]}"
}

# ---------- 入力収集 ----------
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
VIDEO_FILES=()
for f in "${FILES[@]}"; do is_video "$f" && VIDEO_FILES+=("$f"); done
if [[ ${#VIDEO_FILES[@]} -eq 0 ]]; then
  err "処理対象の動画が見つかりませんでした（対象拡張子: ${VIDEO_EXTS[*]}）。"; exit 1
fi

mkdir -p "$OUTPUT_DIR"
info "対象 ${#VIDEO_FILES[@]} ファイル / profile=${PROFILE} / res=${RES} / strength=${STRENGTH} / denoise=${DENOISE} / dehaze=${DEHAZE}"
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
    warn "スキップ（既に存在）: $out"; return 0
  fi

  local fps_raw fps
  fps_raw="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
             -of csv=p=0 "$in" 2>/dev/null || echo "30/1")"
  fps="$(awk -F/ 'BEGIN{v=30}{ if ($2>0) v=$1/$2; else v=$1 } END{ printf "%.3f", v }' <<<"$fps_raw")"

  # profile 番号の決定
  local pnum="$PROFILE_NUM"
  if [[ "$pnum" -eq -1 ]]; then                 # same
    pnum="$(detect_profile_num "$in")"
  elif [[ "$pnum" -eq -2 ]]; then               # auto
    if is_prores "$in"; then pnum="$(detect_profile_num "$in")"; else pnum=2; fi
  fi
  local pix; pix="$(pix_fmt_for "$pnum")"
  local vf;  vf="$(build_vf "$fps")"

  dim "  in : $in  (codec=$(codec_name_of "$in"))"
  dim "  out: $out  (prores profile=$pnum, pix=$pix, ${fps}fps)"
  dim "  vf : $vf"

  local -a cmd=(
    ffmpeg -hide_banner -y -i "$in"
    -vf "$vf"
    -map 0:v:0 -map "0:a?"
    -c:v prores_ks -profile:v "$pnum" -pix_fmt "$pix" -vendor apl0
    -c:a copy
    -map_metadata 0 -movflags +write_colr
    "$out"
  )

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '   '; printf '%q ' "${cmd[@]}"; echo; return 0
  fi
  if "${cmd[@]}" </dev/null >/dev/null 2>"${out}.log"; then
    rm -f "${out}.log"; ok "完了: $out"
  else
    err "失敗: $in  （ログ: ${out}.log）"; return 1
  fi
}
export -f process_one info ok warn err dim build_vf scale_filter pix_fmt_for \
          detect_profile_num denoise_filter codec_name_of is_prores
export OUTPUT_DIR PROFILE PROFILE_NUM RES STRENGTH DENOISE DEHAZE SHARPEN NORMALIZE LUT DRY_RUN OVERWRITE
export C_RED C_GRN C_YEL C_BLU C_DIM C_RST

# ---------- 実行 ----------
FAIL=0
if [[ "$JOBS" -gt 1 && "$DRY_RUN" -eq 0 ]] && command -v xargs >/dev/null 2>&1; then
  info "並列処理: ${JOBS} 本"
  printf '%s\0' "${VIDEO_FILES[@]}" \
    | xargs -0 -P "$JOBS" -I{} bash -c 'process_one "$@"' _ {} || FAIL=1
else
  for f in "${VIDEO_FILES[@]}"; do process_one "$f" || FAIL=1; done
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  ok "すべて完了しました → ${OUTPUT_DIR}"
else
  warn "一部のファイルで失敗しました。ログ（*.log）を確認してください。"; exit 1
fi
