#!/bin/bash
set -euo pipefail

label="com.ai-reviewer.watcher"
plist_path="${HOME}/Library/LaunchAgents/${label}.plist"
wrapper_path="${HOME}/Library/Application Support/com.ai-reviewer/watcher.sh"

if launchctl bootout "gui/$(id -u)" "$plist_path" 2>/dev/null; then
  echo "Unloaded via launchctl bootout: $label"
elif launchctl unload "$plist_path" 2>/dev/null; then
  echo "Unloaded via legacy launchctl unload: $label"
else
  echo "Agent not loaded."
fi

if [[ -f "$plist_path" ]]; then
  rm "$plist_path"
  echo "Removed plist: $plist_path"
else
  echo "Plist already absent."
fi

if [[ -f "$wrapper_path" ]]; then
  rm "$wrapper_path"
  echo "Removed wrapper: $wrapper_path"
else
  echo "Wrapper already absent."
fi
