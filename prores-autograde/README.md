# ProRes 自動グレーディング＆書き出し (`autograde.sh`)

ハードディスク上の **ProRes 動画（特にライブ映像）をフォルダごと自動で色補正・クリーンアップ**し、
編集向きの **ProRes ファイルとして書き出す**ローカル実行スクリプトです。
暗所ノイズ・モヤ（かすみ）・露出のばらつきまで含めて、見られる状態に自動で整えます。

> ⚠️ このスクリプトは**あなたのPC上（ローカル）で実行**します。ffmpeg が必須です。
> リモート環境やブラウザ内では ProRes を扱えないため、この形にしています。

## 2つの使い方

- **A. Claude Code スキルとして（推奨・おまかせ）** — `.claude/skills/prores-grade/`。
  Claude が各クリップを ffprobe で解析し、**サンプルフレームを実際に見て**ノイズ/モヤ/露出を
  判断し、最適なパラメータでこのスクリプトを自動実行します。「ライブ素材を綺麗にして書き出して」
  のように頼むだけで、クリップごとに判断して処理します。
- **B. スクリプトを直接実行** — パラメータを自分で指定して回すシンプルな使い方（本README）。

## 出力形式の自動判定（`--profile auto` / 既定）

- 入力が **ProRes** → **同じ profile に合わせる**（LT なら LT、HQ なら HQ …）。
- 入力が **ProRes 以外** → **画質と容量のバランスが良い ProRes 422（standard）** へ変換。
- 解像度は既定で **元のまま**（4K なら 4K）。容量を抑えたい時だけ `-r 1080p` 等に落とす。

---

## ProRes と負荷について（先に結論）

- **ProRes は“重い”コーデックではありません。** 各フレームを独立圧縮する
  **イントラフレーム方式**なので、H.264/H.265 より **CPU 負荷は低く、書き出しも高速**です。
- 唯一の難点は **ファイルサイズが大きい**こと。容量が気になる場合は
  解像度を `1080p` に落とす、または軽い profile（`lt` / `standard`）を使ってください。
- **ProRes ＝ 編集ネイティブ形式**そのものなので、書き出したファイルは
  DaVinci Resolve / Premiere Pro / Final Cut Pro などにそのまま読み込んで再編集できます。

| 用途 | おすすめ | 目安 |
|------|----------|------|
| おまかせ（入力に合わせる） | `auto` ※既定 | ProRes は同 profile / それ以外は 422 |
| 標準的な編集・納品 | `hq`（ProRes 422 HQ） | 高画質・実用サイズ |
| 容量を抑えたい | `standard` or `lt` + `1080p` | 中画質・軽量 |
| 合成/アーカイブ | `4444` | 最高画質・大容量 |

---

## 必要なもの

- `ffmpeg` / `ffprobe`（ProRes 対応ビルド）
  - macOS: `brew install ffmpeg`
  - Ubuntu/Debian: `sudo apt install ffmpeg`
  - 確認: `ffmpeg -hide_banner -encoders | grep prores`（`prores_ks` が出ればOK）

## 使い方

```bash
# フォルダ内の動画を全自動処理（profile 自動判定・元解像度）して ./graded へ
./autograde.sh /Volumes/HDD/footage

# ライブの暗所ノイズ＋モヤがある素材（ノイズ中/モヤ 0.4）
./autograde.sh --denoise medium --dehaze 0.4 live1.mov live2.mov

# 1080p に落として容量節約、出力先も指定
./autograde.sh -r 1080p -o ~/Desktop/graded /Volumes/HDD/footage

# 補正を弱め（0.4）にして、個別ファイルだけ処理
./autograde.sh -s 0.4 clipA.mov clipB.mov

# まず何が起きるか確認（実行せずコマンドだけ表示）
./autograde.sh -n /Volumes/HDD/footage
```

出力は `<元ファイル名>_graded.mov` として出力先に保存されます。
既定では既存ファイルはスキップ、`-y` で上書きします。

## オプション

| オプション | 説明 | 既定 |
|-----------|------|------|
| `-o, --output DIR` | 出力先ディレクトリ | `./graded` |
| `-p, --profile NAME` | `auto`/`proxy`/`lt`/`standard`/`hq`/`4444`/`4444xq`/`same` | `auto` |
| `-r, --res SIZE` | `source`/`4k`/`1080p`/`720p` | `source` |
| `-s, --strength N` | 自動補正の強さ 0.0〜1.0 | `0.6` |
| `--denoise MODE` | ノイズ除去 `off`/`light`/`medium`/`strong` | `off` |
| `--dehaze N` | モヤ取り（かすみ除去）0.0〜1.0 | `0` |
| `--sharpen` | 軽いシャープを追加 | off |
| `--no-normalize` | 自動レベル/ホワイトバランスを無効化 | on |
| `--lut FILE.cube` | `.cube` LUT を後段に適用 | なし |
| `-j, --jobs N` | 並列処理数 | `1` |
| `-n, --dry-run` | 実行せずコマンド表示 | off |
| `-y, --overwrite` | 既存出力を上書き | off |

- `--profile auto`（既定）: ProRes は同 profile、それ以外は 422 standard に。
- `--profile same`: 入力 ProRes と常に同じ profile で書き出す。

## 自動補正の中身

各クリップに対して、次の順で適用します（処理順が画質に効くよう設計）:

1. **ノイズ除去**（`--denoise`）— `hqdn3d` による時空間ノイズ低減。**シャープ/コントラスト前**に
   かけることでノイズの増幅を防ぎます。ライブの暗所ザラつき対策。
2. **自動レベル / ホワイトバランス** — `normalize` で黒・白レベルと色被りを自動補正。
   **約0.7秒の時間平滑化**でフレーム間のチラつきを防止。
3. **トーンの微調整** — コントラスト・彩度・ガンマを `--strength` に比例して軽く持ち上げ。
4. **モヤ取り**（`--dehaze`）— 大半径アンシャープ（局所コントラスト＝クラリティ）＋軽い
   コントラスト追い込みで、白っぽい霞みを抜いてヌケを良くします。
5. （任意）**LUT** — `.cube` を適用してルックを統一。
6. （任意）**シャープ** — `--sharpen` で細部のエッジ強調。

音声は再エンコードせずそのままコピー（`-c:a copy`）、メタデータも可能な範囲で引き継ぎます。

## 注意点

- **自動補正は万能ではありません。** 素材の傾向が大きく異なる場合や、
  作品としての本格的なカラーグレーディングが必要な場合は、
  自動補正で下地を整えたうえで DaVinci Resolve 等での手動調整をおすすめします。
- LUT が対数（Log）素材前提の場合、`normalize` と併用すると意図とズレることがあります。
  その場合は `--no-normalize --lut yourlog2rec709.cube` のように LUT 単体で使ってください。
- まず `-n`（ドライラン）で対象ファイルと適用フィルタを確認してから本実行すると安全です。
