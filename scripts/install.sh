#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/install.sh [--config <path>] [--no-build]

Builds a release app and installs it to ~/Applications. If --config is supplied,
copies and validates that config at
~/Library/Application Support/com.ai-reviewer/config.json.
USAGE
}

repo_root=$(cd "$(dirname "$0")/.." && pwd)
app_name="AI Reviewer.app"
source_app="$repo_root/build/$app_name"
install_root="$HOME/Applications"
target_app="$install_root/$app_name"
config_source=""
config_target="$HOME/Library/Application Support/com.ai-reviewer/config.json"
should_build=1

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
    --no-build)
      should_build=0
      shift
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

"$repo_root/scripts/preflight.sh" --install
if [[ "$should_build" -eq 1 ]]; then
  AI_REVIEWER_BUILD_CONFIGURATION=release "$repo_root/scripts/build.sh"
elif [[ ! -d "$source_app" ]]; then
  echo "Missing $source_app. Run scripts/build.sh first or omit --no-build." >&2
  exit 1
fi

if [[ -n "$config_source" ]]; then
  if [[ ! -f "$config_source" ]]; then
    echo "Missing config: $config_source" >&2
    exit 1
  fi
  "$source_app/Contents/MacOS/ai-reviewer-watcher" validate --config "$config_source"
fi

mkdir -p "$install_root"
staged_app="$install_root/.AI Reviewer.app.installing.$$"
previous_app="$install_root/.AI Reviewer.app.previous.$$"
staged_config=""
cleanup() {
  rm -rf -- "$staged_app"
  if [[ -n "$staged_config" ]]; then
    rm -f -- "$staged_config"
  fi
  if [[ -e "$previous_app" ]]; then
    if [[ ! -e "$target_app" ]]; then
      mv "$previous_app" "$target_app"
    else
      rm -rf -- "$previous_app"
    fi
  fi
}
trap cleanup EXIT

ditto "$source_app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"

if [[ -e "$target_app" ]]; then
  mv "$target_app" "$previous_app"
fi
mv "$staged_app" "$target_app"
if [[ -e "$previous_app" ]]; then
  rm -rf -- "$previous_app"
fi

echo "Installed $target_app"

if [[ -n "$config_source" ]]; then
  mkdir -p "$(dirname "$config_target")"
  staged_config="$config_target.installing.$$"
  cp "$config_source" "$staged_config"
  if [[ -f "$config_target" ]]; then
    cp -p "$config_target" "$config_target.install-backup"
  fi
  mv -f "$staged_config" "$config_target"
  echo "Installed config $config_target"
fi
