#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  patch|minor|major) [[ $# -eq 1 ]] || { echo "Usage: bash scripts/release.sh patch|minor|major" >&2; exit 2; } ;;
  *) echo "Usage: bash scripts/release.sh patch|minor|major" >&2; exit 2 ;;
esac
[[ "$(git branch --show-current)" == main ]] || { echo "main ブランチで実行してください。" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "変更をコミットしてから実行してください。" >&2; exit 1; }
git fetch --quiet origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse FETCH_HEAD)" ]] || { echo "main と origin/main を同期してから実行してください。" >&2; exit 1; }

version="$(python3 scripts/package.py --check-version)"
IFS=. read -r major minor patch <<< "$version"
case "$1" in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
esac
next="$major.$minor.$patch"
tag="v$next"
if git show-ref --verify --quiet "refs/tags/$tag"; then
  echo "$tag はすでにローカルにあります。" >&2; exit 1
fi
remote_tag="$(git ls-remote --tags origin "refs/tags/$tag")"
[[ -z "$remote_tag" ]] || { echo "$tag はすでに公開されています。" >&2; exit 1; }

printf '%s\n' "$next" > VERSION
git add VERSION
git commit -m "chore: release $tag"
git tag "$tag"
# Update main and its release tag together; never overwrite an existing tag.
git push --atomic origin HEAD:refs/heads/main "refs/tags/$tag:refs/tags/$tag"
echo "$version → $next: タグを push しました。CI がテスト・ビルド後に Release を公開します。"
