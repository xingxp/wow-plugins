#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <workspace-addon-dir> <wow-addons-dir>"
  exit 1
fi

src="$1"
dst_root="$2"

if [[ ! -d "$src" ]]; then
  echo "Source addon directory not found: $src"
  exit 1
fi

if [[ ! -d "$dst_root" ]]; then
  echo "WoW AddOns directory not found: $dst_root"
  exit 1
fi

addon_name="$(basename "$src")"
dst="$dst_root/$addon_name"

mkdir -p "$dst"

rsync -a --delete \
  --exclude '.DS_Store' \
  --exclude '*.bak' \
  --exclude '*.tmp' \
  --exclude '.git' \
  "$src"/ "$dst"/

echo "Synced $addon_name"
echo "  from: $src"
echo "  to:   $dst"
