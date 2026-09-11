# アプリアイコン

`AppIcon.png` は内蔵の image_gen で生成した元画像。アプリと Alfred Workflow で共用する。
`bash scripts/build-icons.sh` が macOS 標準の `sips` で各サイズの PNG を作り、Python 標準ライブラリで ICNS に格納する。通常は `scripts/build.sh` から呼ばれる。
ICNS のサイズ種別と PNG の格納形式は [Pillow の ICNS 実装](https://github.com/python-pillow/Pillow/blob/main/src/PIL/IcnsImagePlugin.py)を参照。

生成時のプロンプト:

```text
Use case: logo-brand. Create one production macOS app icon for Hatebu Search, a personal bookmark search app. Square 1024 x 1024 PNG with genuine transparent alpha outside the icon silhouette. A refined rounded-square deep forest teal tile with very subtle surface depth, containing one bold ivory bookmark ribbon and a small mint magnifying-glass symbol overlapping its lower right. Simple unmistakable geometry readable at 32 pixels, generous clean margins, centered compact composition. Match the app's deep green and mint palette. No lettering, no wordmarks, no B!, no Hatena logo, no decorative sparkles, no mockup, no perspective, no outer background. The actual rounded-square tile should occupy roughly 84 percent of the canvas width and height, with transparent corners and surrounding padding. Render the icon asset only.
```
