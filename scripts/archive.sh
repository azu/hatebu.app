#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build both architectures before calling this script. Never publish a ZIP
# labelled universal if either the app or its standalone CLI is single-arch.
version="$(python3 scripts/package.py --check-version)"
app="dist/HatebuSearch.app"
for binary in "$app/Contents/MacOS/HatebuSearch" "$app/Contents/MacOS/hatebu" dist/workflow/hatebu; do
  lipo "$binary" -verify_arch arm64 x86_64
done
codesign --verify --deep --strict "$app"
codesign --verify --strict dist/workflow/hatebu
cmp "$app/Contents/MacOS/hatebu" dist/workflow/hatebu
cmp "$app/Contents/Resources/HatebuSearch.alfredworkflow" dist/HatebuSearch.alfredworkflow

python3 - <<'PY'
from pathlib import Path
import plistlib
import zipfile

version = Path("VERSION").read_text().strip()
app = Path("dist/HatebuSearch.app/Contents")
info = plistlib.loads((app / "Info.plist").read_bytes())
if info["CFBundleShortVersionString"] != version or info["CFBundleVersion"] != version:
    raise SystemExit("App version differs from VERSION; rebuild before archiving")
with zipfile.ZipFile("dist/HatebuSearch.alfredworkflow") as workflow:
    info = plistlib.loads(workflow.read("info.plist"))
    if info["version"] != version:
        raise SystemExit("Workflow version differs from VERSION; rebuild before archiving")
    if workflow.read("hatebu") != (app / "MacOS/hatebu").read_bytes():
        raise SystemExit("App and archived workflow contain different CLIs")
    if not (workflow.getinfo("hatebu").external_attr >> 16) & 0o111:
        raise SystemExit("Workflow CLI lost executable permissions")
PY

mkdir -p dist/release
# This directory contains generated release assets only. Drop older archives so
# a later build cannot upload stale versions through the CI artifact glob.
rm -f dist/release/HatebuSearch-*-universal.zip
archive="HatebuSearch-$version-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/release/$archive"
cp dist/HatebuSearch.alfredworkflow dist/release/HatebuSearch.alfredworkflow
cd dist/release
unzip -tq "$archive"
unzip -tq HatebuSearch.alfredworkflow
shasum -a 256 "$archive" HatebuSearch.alfredworkflow > SHA256SUMS
shasum -a 256 -c SHA256SUMS
echo "Release assets are in dist/release"
