---
name: prores-grade
description: >-
  ローカルの ProRes 動画（特にライブ映像）を1本ずつ解析し、ノイズ・モヤ・露出・色被りを
  AI が判断して自動グレーディング＆クリーンアップし、編集向きの ProRes として書き出す。
  入力が ProRes なら同じ profile（LT→LT 等）と解像度に合わせ、それ以外なら画質と容量の
  バランスが良い ProRes 422 に変換する。Use when the user wants to grade / color-correct /
  clean up / denoise / dehaze / batch-convert ProRes or live-concert footage and export ProRes.
  Triggers: "prores", "グレーディング", "色補正", "ライブ映像", "ノイズ", "モヤ", "書き出し".
---

# ProRes 自動グレーディング＆クリーンアップ

ローカルの ProRes 素材を **1クリップずつ AI が目視で判断** し、最適な補正をかけて
編集向き ProRes として書き出すスキル。ライブ映像にありがちな暗所ノイズ・モヤ（かすみ）・
露出のばらつき・色被りをクリップごとに見極めて処理する。

エンジンは ffmpeg ベースのスクリプト `prores-autograde/autograde.sh`（このリポジトリ内）。
このスキルは「各クリップをどう処理すべきか」を判断してエンジンを呼ぶ役割を担う。

## 前提

- **ローカル実行**（ユーザーのマシン）で、`ffmpeg` / `ffprobe` が必要。
  無ければ導入を案内して停止する（`brew install ffmpeg` / `apt install ffmpeg`）。
- 実データを見ずにパラメータを決めない。**必ずサンプルフレームを抽出して目視**する。

## 手順

### 1. 対象の把握
- ユーザーが指定したファイル/フォルダを確認。未指定なら対象パスを尋ねる。
- 出力先（既定 `./graded`）と、容量を抑えたい等の希望（解像度を落とすか）を確認。
  特に希望が無ければ **解像度は元のまま**（4K なら 4K）。

### 2. クリップごとにメタデータを取得
各ファイルに対して:
```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,codec_tag_string,width,height,r_frame_rate,pix_fmt \
  -show_entries format=duration -of default=noprint_wrappers=1 "<file>"
```
- `codec_name=prores` かどうかで出力 profile 方針が決まる（下記「出力形式の決定」）。
- 幅・高さ・fps は記録しておく。

### 3. サンプルフレームを抽出して目視
クリップの序盤・中盤・終盤あたりから 2〜3 枚を PNG で抜き、Read ツールで実際に見る:
```bash
ffmpeg -hide_banner -y -ss <t> -i "<file>" -frames:v 1 -q:v 2 \
  "<scratch>/<stem>_<t>s.png"
```
（暗いライブは中盤の明るい場面も選ぶと判断しやすい。）

見るべきポイントと判断:
| 観察 | 判断するパラメータ |
|------|-------------------|
| ザラつき・色ノイズ（暗部に顕著） | `--denoise off/light/medium/strong` |
| 白っぽくコントラストが浅い＝モヤ/かすみ | `--dehaze 0.2〜0.6` |
| 全体に暗い/明るすぎ・色被り | `--strength`（自動レベルの効き）で調整 |
| 眠い/甘い解像感 | `--sharpen`（かけ過ぎ注意、ノイズ源なら denoise 優先） |

### 4. パラメータの目安
- **ノイズ**: わずか→`light` / ライブ暗所で明らか→`medium` / 高ISOで派手→`strong`。
  ノイズが強い場合はシャープを控える（`--sharpen` を付けない）。
- **モヤ（dehaze）**: 軽い霞み→`0.25`、はっきり白っぽい→`0.4`、強い逆光スモーク→`0.6`。
  かけ過ぎると不自然に硬くなるので上げ過ぎない。
- **strength**: 既定 `0.6`。素材が既に整っていれば `0.4`、フラット/Log 寄りなら `0.7`。
- Log 収録素材で専用 LUT がある場合は `--no-normalize --lut <log2rec709>.cube` を優先。

### 5. 出力形式の決定（エンジンが自動処理）
- `--profile auto`（既定）に任せる:
  - 入力が ProRes → **同じ profile**（LT→LT, HQ→HQ …）に合わせる。
  - 入力が ProRes 以外 → **ProRes 422（standard）**（画質良／容量控えめ）。
- 解像度は `--res source`（既定）で元のまま。ユーザーが容量削減を望む場合のみ
  `--res 1080p` 等を提案・適用する。

### 6. 実行
判断したパラメータでクリップ（またはグループ）ごとに実行する。まず 1 本で確認 → 残りへ。
```bash
prores-autograde/autograde.sh \
  --denoise medium --dehaze 0.4 -s 0.6 \
  -o "<出力先>" "<file>"
```
- 傾向が揃った素材はフォルダ単位でまとめて実行してよい。
- 傾向がバラバラなら、似たクリップごとにパラメータを変えて分けて実行する。
- 大量処理では `-j <N>` で並列化（N はコア数の半分程度から）。

### 7. 結果の報告
処理したファイル、各クリップに適用した判断（denoise/dehaze/strength/profile/解像度）を
表で提示する。1 本試した段階でユーザーに仕上がり確認を促すと安全。

## 注意
- 自動判断はあくまで下地作り。作品レベルの本格グレーディングが要る場合は、
  この自動処理で整えたうえで DaVinci Resolve 等での手動調整を勧める。
- フレーム抽出用の PNG はスクラッチ領域に置き、処理後は片付ける。
- `-n`（ドライラン）で適用フィルタを事前確認できることをユーザーに伝えてよい。
