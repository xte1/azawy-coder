#!/usr/bin/env bash
set -euo pipefail

DEST="${1:-.}"
if [[ ! -d "$DEST/.git" ]]; then
  echo "Usage: $0 /path/to/ios-builder-clone" >&2
  echo "The destination must be an existing Git repository." >&2
  exit 2
fi
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DEST/ios-app" "$DEST/.github/workflows"
cp -R "$SOURCE_DIR/ios-app/" "$DEST/ios-app/"
cp "$SOURCE_DIR/.github/workflows/ios-app-build.yml" "$DEST/.github/workflows/ios-app-build.yml"
cp "$SOURCE_DIR/README-AR.md" "$DEST/README-Builder-Mobile-AR.md"
echo "Builder Mobile files copied into: $DEST"
echo "Review changes, then commit and push them to GitHub."
