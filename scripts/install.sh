#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
app_name="AI Reviewer.app"
source_app="$repo_root/build/$app_name"
install_root="$HOME/Applications"
target_app="$install_root/$app_name"

if [[ ! -d "$source_app" ]]; then
  "$repo_root/scripts/build.sh"
fi

mkdir -p "$install_root"
if [[ -e "$target_app" ]]; then
  if ! command -v trash >/dev/null 2>&1; then
    echo "Refusing to replace $target_app because trash is unavailable." >&2
    exit 1
  fi
  trash "$target_app"
fi
cp -R "$source_app" "$target_app"

echo "Installed $target_app"
