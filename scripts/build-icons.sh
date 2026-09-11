#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

iconset=".build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
# Store the PNG representations directly in the ICNS container. This avoids
# depending on the Icon Services encoder in non-interactive build environments.
python3 - <<'PY'
from pathlib import Path
import struct

iconset = Path(".build/AppIcon.iconset")
representations = {
    b"icp4": "16x16", b"icp5": "32x32", b"ic07": "128x128",
    b"ic08": "256x256", b"ic09": "512x512", b"ic10": "512x512@2x",
    b"ic11": "16x16@2x", b"ic12": "32x32@2x",
    b"ic13": "128x128@2x", b"ic14": "256x256@2x",
}
chunks = []
for kind, size in representations.items():
    png = (iconset / f"icon_{size}.png").read_bytes()
    chunks.append(struct.pack(">4sI", kind, len(png) + 8) + png)
contents = b"".join(chunks)
Path(".build/AppIcon.icns").write_bytes(struct.pack(">4sI", b"icns", len(contents) + 8) + contents)
PY
