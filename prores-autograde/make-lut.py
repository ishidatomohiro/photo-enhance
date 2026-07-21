#!/usr/bin/env python3
"""
make-lut.py — グレーディングの「ルック」を .cube 3D LUT として書き出す。

生成した .cube は以下すべてで読み込める（＝AIが決めた色を1ファイルで持ち運べる）:
  * ffmpeg / autograde.sh   … --lut <file>.cube
  * Premiere Pro (Lumetri)  … 基本補正 or クリエイティブの「Look」
  * DaVinci Resolve         … LUT フォルダに置いて右クリック適用
  * iPhone / iPad の LumaFusion … LUT として読み込み（ProRes 素材にそのまま適用可）

使い方:
  python3 make-lut.py -o live.cube --preset live
  python3 make-lut.py -o my.cube --contrast 1.10 --saturation 1.20 --gamma 1.05 --temp 0.05

Rec.709 前提。露出の自動補正やクリップ個別のノイズ/モヤ除去は LUT には焼けないため、
LUT は「ルック（色の傾向）」を担い、下処理は autograde.sh / NLE 側で行う想定。
"""
import argparse
import sys

REC709 = (0.2126, 0.7152, 0.0722)

PRESETS = {
    # name:      contrast, saturation, gamma, lift,  gain, temp,  tint, split
    "natural":  (1.05, 1.08, 1.00, 0.00, 1.00, 0.00, 0.00, 0.0),
    "live":     (1.12, 1.18, 1.05, 0.015, 1.00, 0.05, 0.00, 0.0),  # ライブ: 締めつつ暗部を開く・僅かに暖色
    "warm":     (1.06, 1.10, 1.00, 0.00, 1.00, 0.15, 0.00, 0.0),
    "cool":     (1.06, 1.08, 1.00, 0.00, 1.00, -0.12, 0.00, 0.0),
    "teal-orange": (1.10, 1.12, 1.00, 0.00, 1.00, 0.02, 0.00, 0.35),  # シネマ風スプリットトーン
}


def clamp01(x):
    return 0.0 if x < 0.0 else 1.0 if x > 1.0 else x


def apply_look(r, g, b, p):
    contrast, sat, gamma, lift, gain, temp, tint, split = p

    # 1) ゲイン → リフト（暗部持ち上げ）→ ガンマ
    r, g, b = r * gain, g * gain, b * gain
    if lift:
        r = r + lift * (1.0 - r)
        g = g + lift * (1.0 - g)
        b = b + lift * (1.0 - b)
    if gamma and gamma != 1.0:
        inv = 1.0 / gamma
        r, g, b = clamp01(r) ** inv, clamp01(g) ** inv, clamp01(b) ** inv

    # 2) 色温度 / 色被り
    if temp:
        r *= (1.0 + temp * 0.30)
        b *= (1.0 - temp * 0.30)
    if tint:
        g *= (1.0 + tint * 0.30)

    # 3) スプリットトーン（暗部=ティール / 明部=オレンジ）
    if split:
        lum = REC709[0] * r + REC709[1] * g + REC709[2] * b
        # 明るいほど +1、暗いほど -1 に寄せた係数
        w = (lum - 0.5) * 2.0
        r += split * 0.08 * w        # ハイライトを暖色、シャドウを寒色へ
        b -= split * 0.08 * w
        g += split * 0.02 * w

    # 4) コントラスト（0.5 ピボット）
    if contrast and contrast != 1.0:
        r = (r - 0.5) * contrast + 0.5
        g = (g - 0.5) * contrast + 0.5
        b = (b - 0.5) * contrast + 0.5

    # 5) 彩度（輝度保持）
    if sat and sat != 1.0:
        lum = REC709[0] * r + REC709[1] * g + REC709[2] * b
        r = lum + (r - lum) * sat
        g = lum + (g - lum) * sat
        b = lum + (b - lum) * sat

    return clamp01(r), clamp01(g), clamp01(b)


def main():
    ap = argparse.ArgumentParser(description="グレーディングのルックを .cube LUT に書き出す")
    ap.add_argument("-o", "--output", required=True, help="出力 .cube ファイル")
    ap.add_argument("--preset", choices=sorted(PRESETS), help="ベースにするプリセット")
    ap.add_argument("--size", type=int, default=33, help="LUT サイズ（既定 33）")
    ap.add_argument("--title", default=None, help="LUT タイトル")
    # 個別上書き（プリセットに対して差分指定できる）
    ap.add_argument("--contrast", type=float)
    ap.add_argument("--saturation", type=float)
    ap.add_argument("--gamma", type=float)
    ap.add_argument("--lift", type=float)
    ap.add_argument("--gain", type=float)
    ap.add_argument("--temp", type=float, help="色温度 -1〜1（+で暖色）")
    ap.add_argument("--tint", type=float, help="色被り -1〜1（+で緑）")
    ap.add_argument("--split", type=float, help="ティール&オレンジ 0〜1")
    args = ap.parse_args()

    base = list(PRESETS.get(args.preset, PRESETS["natural"]))
    # 位置: [contrast, sat, gamma, lift, gain, temp, tint, split]
    for idx, val in enumerate([args.contrast, args.saturation, args.gamma,
                               args.lift, args.gain, args.temp, args.tint, args.split]):
        if val is not None:
            base[idx] = val
    p = tuple(base)

    n = args.size
    if n < 2 or n > 129:
        print("size は 2〜129 の範囲で指定してください", file=sys.stderr)
        sys.exit(1)

    title = args.title or (args.preset or "custom")
    lines = [f'TITLE "{title}"', f"LUT_3D_SIZE {n}",
             "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
    # .cube 仕様: 赤が最速で変化 → 赤を内側ループに
    denom = n - 1
    for bi in range(n):
        b = bi / denom
        for gi in range(n):
            g = gi / denom
            for ri in range(n):
                r = ri / denom
                rr, gg, bb = apply_look(r, g, b, p)
                lines.append(f"{rr:.6f} {gg:.6f} {bb:.6f}")

    with open(args.output, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"✓ 書き出し: {args.output}  (size={n}, preset={args.preset or 'custom'})")


if __name__ == "__main__":
    main()
