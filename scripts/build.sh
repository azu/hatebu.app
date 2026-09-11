#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
build_args=(-c release --disable-sandbox --cache-path .build/cache)
version_args=(--check-version)
case "${1:-}" in
  --universal) build_args+=(--arch arm64 --arch x86_64) ;;
  "") ;;
  *) echo "Usage: bash scripts/build.sh [--universal]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  echo "Usage: bash scripts/build.sh [--universal]" >&2
  exit 2
fi
if [[ -n "${HATEBU_RELEASE_TAG:-}" ]]; then
  version_args+=(--tag "$HATEBU_RELEASE_TAG")
fi
python3 scripts/package.py "${version_args[@]}"
swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
codesign --force --sign - "$bin_dir/hatebu"
python3 scripts/package.py --bin-dir "$bin_dir"
codesign --force --sign - dist/HatebuSearch.app
codesign --verify --deep --strict dist/HatebuSearch.app
codesign --verify --strict dist/workflow/hatebu
echo "Built dist/HatebuSearch.app and dist/HatebuSearch.alfredworkflow"
