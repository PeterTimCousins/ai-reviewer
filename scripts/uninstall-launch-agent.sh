#!/bin/bash
set -euo pipefail

label="com.ai-reviewer.watcher"
plist_path="${HOME}/Library/LaunchAgents/${label}.plist"
wrapper_path="${HOME}/Library/Application Support/com.ai-reviewer/watcher.sh"

trash_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return 0
  fi

  if ! command -v trash >/dev/null 2>&1; then
    echo "Refusing to remove $path because trash is unavailable." >&2
    exit 1
  fi

  trash "$path"
}

if launchctl bootout "gui/$(id -u)" "$plist_path" 2>/dev/null; then
  echo "Unloaded via launchctl bootout: $label"
elif launchctl unload "$plist_path" 2>/dev/null; then
  echo "Unloaded via legacy launchctl unload: $label"
else
  echo "Agent not loaded."
fi

if [[ -f "$plist_path" ]]; then
  trash_path "$plist_path"
  echo "Trashed plist: $plist_path"
else
  echo "Plist already absent."
fi

if [[ -f "$wrapper_path" ]]; then
  trash_path "$wrapper_path"
  echo "Trashed legacy wrapper: $wrapper_path"
else
  echo "Wrapper already absent."
fi
