# 環境別ワークフロー（PC / Premiere / DaVinci / iPhone）

このツール群は「**AIが決めた色・処理を、各環境で使える形にして渡す**」ことを目的にしています。
全環境をつなぐ鍵は **`.cube` LUT**（`make-lut.py` で生成）。LUT はルック（色）を1ファイルに
焼いたもので、PCのNLEでも iPhone でも同じ色を再現できます。

| やりたいこと | 担当 | 焼けるもの |
|-------------|------|-----------|
| 色のルック（トーン/彩度/雰囲気） | `.cube` LUT | ✅ どの環境でも共通で使える |
| クリップ個別の露出/色被り自動補正 | autograde.sh / NLE | ❌ LUTには焼けない（クリップ依存） |
| ノイズ除去・モヤ取り | autograde.sh / NLE | ❌ LUTには焼けない |

→ **LUT＝ルック担当、下処理（露出・ノイズ・モヤ）＝処理エンジン担当**、と役割を分けます。

---

## A. PC・全自動（このリポジトリの `autograde.sh`）

一番手間がかからない。Claude Code スキル `prores-grade` に任せれば、クリップごとに
判断して色補正・ノイズ除去・モヤ取り＋ProRes書き出しまで自動。手動なら:

```bash
./autograde.sh --denoise medium --dehaze 0.4 /Volumes/HDD/live
# ルックLUTも重ねたい場合
python3 make-lut.py -o live.cube --preset live
./autograde.sh --lut live.cube --denoise medium --dehaze 0.4 /Volumes/HDD/live
```

## B. Adobe Premiere Pro

ルックLUTを Lumetri に読み込むだけで、AIが決めた色を適用できます。

1. `python3 make-lut.py -o live.cube --preset live` で LUT を作る。
2. Premiere でクリップ選択 →「Lumetri カラー」→「クリエイティブ」→「Look」→
   `参照…` から `live.cube` を選択（または「基本補正」の「入力 LUT」）。
3. 露出/ノイズはクリップごとに Lumetri の基本補正・Media Encoder 側で調整。
4. 書き出しは Media Encoder で ProRes プリセット（422 HQ 等）を選択。

> 大量素材を「入れたら自動でProRes書き出し」にしたい場合は、Media Encoder の
> **ウォッチフォルダー**＋ProResプリセットが便利（フォルダに入れた素材を自動変換）。

## C. DaVinci Resolve（グレーディング本命・無料版可）

### C-1. 全自動（Python API・推奨）
`resolve-autograde.py` が「取り込み → ルック(LUT/CDL)適用 → ProRes 書き出し」を自動化します。
Apple Silicon Mac なら ProRes はハード処理で軽快に回ります。

準備（初回のみ）:
1. DaVinci Resolve を起動 → 環境設定 → システム → 一般 →
   **「ローカル/ネットワークからの外部スクリプトを使用」を有効**にする。

実行:
```bash
# まずルックLUTを用意（任意）
python3 make-lut.py -o ~/LUTs/live.cube --preset live
# Resolve を起動した状態で、ランチャー経由で実行
./run-resolve.command /Volumes/HDD/live -o ~/Movies/graded --lut ~/LUTs/live.cube -p hq
```
`run-resolve.command` が Resolve のスクリプティング環境変数を設定して起動します。

> API の制約: クリップ内容を見た**自動カラーバランス**や強力な**時間ノイズ除去**は
> API から自動化できません（NR は Studio 版・GUI 寄り）。そこは **先に autograde.sh(ffmpeg)
> で露出補正・ノイズ除去・モヤ取りを済ませてから** Resolve でルック＋ProRes書き出し、
> という分担が最も確実です。

### C-2. 手動（GUI）
1. `make-lut.py` で作った `.cube` を Resolve の LUT フォルダに置く
   （プロジェクト設定 →「カラーマネジメント」→「LUT フォルダを開く」）。
2. Resolve を再起動 →「Color」ページでノードを右クリック →「LUT」→ 生成した LUT。
3. 自動バランスは「カラー」→ ホイール上部の **Auto Balance**、ノイズ除去は
   Studio版の Temporal/Spatial NR（無料版は空間NR相当を工夫）。
4. 「Deliver」で ProRes を選んで書き出し（Mac は 422/4444、Windows は環境依存）。

## D. iPhone / iPad で編集（LumaFusion）

**iPhone で ProRes を編集して書き出す現実解は LumaFusion です。**
（iPhone 13 Pro 以降は ProRes 撮影可。LumaFusion は ProRes の読み込み・書き出し・
`.cube` LUT 適用に対応。）

1. `make-lut.py` で作った `live.cube` を iPhone に送る
   （AirDrop / iCloud Drive / Files アプリ経由）。
2. LumaFusion でプロジェクトにクリップを配置 → クリップを選択 →
   「カラー＆エフェクト」→「LUT」→ Files から `live.cube` を読み込み。
3. 露出・彩度・ホワイトバランスは LumaFusion のカラーツールで微調整
   （自動一括ではなく手動。ここは PC の autograde ほど自動化できない）。
4. 共有 →「ムービー」→ コーデックに **ProRes** を選んで書き出し。

### iPhone 編集の限界（正直な整理）
- **色（ルック）は LUT で PC と同じにできる** → ここは最高。
- **クリップ個別の自動補正・強力なノイズ除去/モヤ取りは iPhone 単体では弱い**。
  ライブの暗所ノイズをしっかり消したいなら、**PC(autograde/Resolve)で下処理 → 
  その ProRes を iPhone に渡して編集**、という分担が最も綺麗で速い。
- 完全 iPhone 完結にこだわるなら、LumaFusion + LUT + 手動調整が上限、と考えてください。

---

## おすすめの分担（ライブ素材中心の場合）

```
[PC] autograde.sh / Resolve で
      ・クリップごとに露出/色被りを自動補正
      ・暗所ノイズ除去・モヤ取り
      ・ルックLUTを適用
      ・ProRes(元と同形式)で書き出し
        │
        ▼  クリーンな ProRes（＋必要なら同じ live.cube）
[iPhone] LumaFusion でカット編集・テロップ・仕上げ → ProRes 書き出し
```

「重い下処理は自動化できるPCで、感覚的なカット編集は手元のiPhoneで」——
この組み合わせが、品質・速度・iPhoneでの快適さのバランスが最も良い構成です。
