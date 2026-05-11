#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/install.sh [--config <path>]

Installs build/AI Reviewer.app to ~/Applications. If --config is supplied,
copies that config to ~/Library/Application Support/com.ai-reviewer/config.json.
USAGE
}

repo_root=$(cd "$(dirname "$0")/.." && pwd)
app_name="AI Reviewer.app"
source_app="$repo_root/build/$app_name"
install_root="$HOME/Applications"
target_app="$install_root/$app_name"
config_source=""
config_target="$HOME/Library/Application Support/com.ai-reviewer/config.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      config_source="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

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

if [[ -n "$config_source" ]]; then
  if [[ ! -f "$config_source" ]]; then
    echo "Missing config: $config_source" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$config_target")"
  cp "$config_source" "$config_target"
  echo "Installed config $config_target"
fi
