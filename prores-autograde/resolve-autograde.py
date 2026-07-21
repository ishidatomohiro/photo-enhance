#!/usr/bin/env python3
"""
resolve-autograde.py — DaVinci Resolve を Python API で自動運転し、
  クリップ取り込み → ルックLUT/CDL適用 → ProRes 書き出し までを一括実行する。

  ※ これは「あなたの Mac 上で、DaVinci Resolve を起動した状態」で実行するスクリプトです。
     Resolve のスクリプティングを有効にしておく必要があります
     （環境変数の設定は同梱の run-resolve.command が行います）。

前提:
  * DaVinci Resolve（無料版可） 18 以降を起動しておく
  * 環境変数 RESOLVE_SCRIPT_API / RESOLVE_SCRIPT_LIB / PYTHONPATH が通っていること
    （run-resolve.command 経由なら自動設定）

使い方（推奨: 同梱ランチャー経由）:
  ./run-resolve.command /Volumes/HDD/live \
      --output ~/Movies/graded --lut ~/LUTs/live.cube --profile hq

直接実行する場合:
  python3 resolve-autograde.py <入力フォルダ or ファイル...> [オプション]

主なオプション:
  -o, --output DIR   書き出し先          (既定: ~/Movies/graded)
  -p, --profile      hq|standard|lt|proxy|4444|4444xq   (既定: hq)
  --lut FILE.cube    全クリップに適用するルックLUT（make-lut.py で生成したもの）
  --sat N            彩度 CDL（既定 1.0＝変更なし）
  --slope N          スロープ/ゲイン CDL（既定 1.0）
  --power N          パワー/ガンマ CDL（既定 1.0）
  --project NAME     Resolve プロジェクト名 (既定: autograde)
  --res WxH          タイムライン解像度（例 3840x2160。未指定なら Resolve の既定）

Resolve API の制約（正直な整理）:
  * クリップ内容を見た「自動カラーバランス」や強力な時間ノイズ除去は API から直接は
    自動化できない（NR は Studio 版・GUI 操作寄り）。そこは:
      - 事前に autograde.sh（ffmpeg）で自動レベル・ノイズ除去・モヤ取りを済ませる、
      - もしくは Resolve 上で手動調整する、
    という分担にする。本スクリプトは「取り込み＋ルック（LUT/CDL）＋ProRes書き出し」を自動化する。
"""
import argparse
import os
import sys
import time

VIDEO_EXTS = {".mov", ".mxf", ".mp4", ".mkv", ".avi", ".m4v", ".braw", ".r3d"}

# profile 名 → Resolve の ProRes コーデック識別子
PRORES_CODEC = {
    "proxy":  "ProRes422Proxy",
    "lt":     "ProRes422LT",
    "standard": "ProRes422",
    "hq":     "ProRes422HQ",
    "4444":   "ProRes4444",
    "4444xq": "ProRes4444XQ",
}


def die(msg, code=1):
    print(f"✗ {msg}", file=sys.stderr)
    sys.exit(code)


def connect_resolve():
    """Resolve のスクリプティングモジュールを読み込んで接続する。"""
    try:
        import DaVinciResolveScript as dvr  # type: ignore
    except ImportError:
        # 代表的な標準パスを補ってリトライ（macOS）
        default = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules"
        sys.path.append(os.environ.get("RESOLVE_SCRIPT_LIB_MODULES", default))
        try:
            import DaVinciResolveScript as dvr  # type: ignore
        except ImportError:
            die("DaVinciResolveScript が読み込めません。run-resolve.command 経由で実行するか、\n"
                "   RESOLVE_SCRIPT_API / RESOLVE_SCRIPT_LIB / PYTHONPATH を設定してください。")
    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        die("Resolve に接続できません。Resolve を起動し、環境設定で外部スクリプトを許可してください。")
    return resolve


def collect_files(inputs):
    files = []
    for inp in inputs:
        if os.path.isdir(inp):
            for root, _, names in os.walk(inp):
                for n in sorted(names):
                    if os.path.splitext(n)[1].lower() in VIDEO_EXTS:
                        files.append(os.path.join(root, n))
        elif os.path.isfile(inp):
            files.append(inp)
        else:
            print(f"⚠ 見つかりません: {inp}", file=sys.stderr)
    return files


def main():
    ap = argparse.ArgumentParser(description="DaVinci Resolve 自動グレーディング＆ProRes書き出し")
    ap.add_argument("inputs", nargs="+", help="入力フォルダ or ファイル")
    ap.add_argument("-o", "--output", default=os.path.expanduser("~/Movies/graded"))
    ap.add_argument("-p", "--profile", default="hq", choices=sorted(PRORES_CODEC))
    ap.add_argument("--lut", default=None, help="全クリップに適用する .cube LUT")
    ap.add_argument("--sat", type=float, default=1.0)
    ap.add_argument("--slope", type=float, default=1.0)
    ap.add_argument("--power", type=float, default=1.0)
    ap.add_argument("--project", default="autograde")
    ap.add_argument("--res", default=None, help="タイムライン解像度 WxH（例 3840x2160）")
    args = ap.parse_args()

    if args.lut and not os.path.isfile(args.lut):
        die(f"LUT が見つかりません: {args.lut}")
    files = collect_files(args.inputs)
    if not files:
        die("処理対象の動画が見つかりませんでした。")
    os.makedirs(args.output, exist_ok=True)

    resolve = connect_resolve()
    pm = resolve.GetProjectManager()
    proj = pm.CreateProject(args.project) or pm.LoadProject(args.project)
    if proj is None:
        die(f"プロジェクトを作成/オープンできません: {args.project}")
    print(f"▶ プロジェクト: {args.project} / {len(files)} ファイル / profile={args.profile}")

    if args.res:
        try:
            w, h = args.res.lower().split("x")
            proj.SetSetting("timelineResolutionWidth", w)
            proj.SetSetting("timelineResolutionHeight", h)
        except ValueError:
            die("--res は WxH 形式で指定してください（例 3840x2160）")

    media_pool = proj.GetMediaPool()
    media_storage = resolve.GetMediaStorage()

    # 取り込み
    items = media_storage.AddItemListToMediaPool(files)
    if not items:
        items = media_pool.ImportMedia(files)
    if not items:
        die("メディアの取り込みに失敗しました。")
    print(f"✓ 取り込み: {len(items)} クリップ")

    # タイムライン作成
    timeline = media_pool.CreateTimelineFromClips("autograde_TL", items)
    if timeline is None:
        die("タイムラインの作成に失敗しました。")
    proj.SetCurrentTimeline(timeline)

    # 各クリップに CDL（基本トーン）と LUT（ルック）を適用
    cdl = {
        "NodeIndex": "1",
        "Slope":  f"{args.slope} {args.slope} {args.slope}",
        "Offset": "0 0 0",
        "Power":  f"{args.power} {args.power} {args.power}",
        "Saturation": f"{args.sat}",
    }
    applied = 0
    track_count = timeline.GetTrackCount("video")
    for t in range(1, track_count + 1):
        for ti in (timeline.GetItemListInTrack("video", t) or []):
            try:
                if args.slope != 1.0 or args.power != 1.0 or args.sat != 1.0:
                    ti.SetCDL(cdl)
                if args.lut:
                    ti.SetLUT(1, args.lut)
                applied += 1
            except Exception as e:  # noqa: BLE001
                print(f"⚠ 適用スキップ: {getattr(ti, 'GetName', lambda: '?')()} ({e})", file=sys.stderr)
    print(f"✓ グレード適用: {applied} クリップ" + (f" / LUT={os.path.basename(args.lut)}" if args.lut else ""))

    # 書き出し設定（ProRes / QuickTime mov）
    proj.SetCurrentRenderFormatAndCodec("mov", PRORES_CODEC[args.profile])
    proj.SetRenderSettings({
        "TargetDir": args.output,
        "SelectAllFrames": True,
        "ExportVideo": True,
        "ExportAudio": True,
    })
    job_id = proj.AddRenderJob()
    if not job_id:
        die("レンダージョブを追加できませんでした。")
    print(f"▶ 書き出し開始 → {args.output}")
    proj.StartRendering(job_id)

    # 進捗待ち
    while proj.IsRenderingInProgress():
        try:
            status = proj.GetRenderJobStatus(job_id) or {}
            pct = status.get("CompletionPercentage", "?")
            print(f"  … {pct}%", end="\r", flush=True)
        except Exception:  # noqa: BLE001
            pass
        time.sleep(2)

    status = proj.GetRenderJobStatus(job_id) or {}
    state = status.get("JobStatus", "Unknown")
    print(f"\n{'✓' if state == 'Complete' else '⚠'} 書き出し {state} → {args.output}")
    pm.SaveProject()


if __name__ == "__main__":
    main()
