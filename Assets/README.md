# アプリアイコン

`AppIcon.png` は内蔵の image_gen で生成・編集した、青地に白いブックマークの元画像。アプリと Alfred Workflow で共用する。
`bash scripts/build-icons.sh` が macOS 標準の `sips` で各サイズの PNG を作り、Python 標準ライブラリで ICNS に格納する。通常は `scripts/build.sh` から呼ばれる。
ICNS のサイズ種別と PNG の格納形式は [Pillow の ICNS 実装](https://github.com/python-pillow/Pillow/blob/main/src/PIL/IcnsImagePlugin.py)を参照。

生成時のプロンプト:

```text
Use case: logo-brand. Create one production macOS app icon for Hatebu Search, a personal bookmark app. Square 1024 x 1024 PNG with genuine transparent alpha outside the icon silhouette. A refined rounded-square saturated cobalt blue tile based on #1671E8, with very subtle surface depth, containing one bold centered ivory bookmark ribbon with a V-shaped notch at the bottom and gently rounded top corners. There is only one symbol: the bookmark. Simple unmistakable geometry readable at 32 pixels, generous clean margins, centered compact composition. No lettering, no wordmarks, no B!, no Hatena logo, no magnifying glass, no decorative sparkles, no mockup, no perspective, no outer background. The actual rounded-square tile should occupy roughly 84 percent of the canvas width and height, with transparent corners and surrounding padding. Render the icon asset only. Use actual transparent pixels outside the blue tile; do not paint a checkerboard pattern.
```
