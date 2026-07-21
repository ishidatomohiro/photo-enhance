#!/usr/bin/env bash
#
# run-resolve.command — macOS 用ランチャー。
#   DaVinci Resolve のスクリプティング環境変数を設定してから resolve-autograde.py を実行する。
#   Finder でダブルクリックしても、ターミナルから叩いてもよい。
#
#   使い方:
#     ./run-resolve.command <入力フォルダ or ファイル...> [resolve-autograde.py のオプション]
#   例:
#     ./run-resolve.command /Volumes/HDD/live -o ~/Movies/graded --lut ~/LUTs/live.cube -p hq
#
set -euo pipefail
cd "$(dirname "$0")"

# DaVinci Resolve の標準スクリプティングパス（macOS）
RES_BASE="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
export RESOLVE_SCRIPT_API="$RES_BASE"
export RESOLVE_SCRIPT_LIB="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
export RESOLVE_SCRIPT_LIB_MODULES="$RES_BASE/Modules"
export PYTHONPATH="${PYTHONPATH:-}:$RES_BASE/Modules"

if [[ ! -e "$RESOLVE_SCRIPT_LIB" ]]; then
  echo "✗ DaVinci Resolve が見つかりません: $RESOLVE_SCRIPT_LIB"
  echo "  Resolve をインストールし、一度起動してから再実行してください。"
  exit 1
fi

# Resolve が同梱する Python でも、システム python3 でも動く。まず python3 を使う。
PY="$(command -v python3 || true)"
[[ -z "$PY" ]] && PY="/usr/bin/python3"

echo "▶ DaVinci Resolve 自動グレーディングを開始します"
echo "  （事前に Resolve を起動し、環境設定 → システム → 一般 で"
echo "   『ローカル/ネットワークからの外部スクリプトを使用』を有効にしてください）"
exec "$PY" "$(dirname "$0")/resolve-autograde.py" "$@"
