#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

config_path="${AI_REVIEWER_CONFIG:-config/local.json}"

if [[ ! -f "$config_path" ]]; then
  echo "Missing $config_path. Copy config/local.example.json to config/local.json and edit it, or set AI_REVIEWER_CONFIG." >&2
  exit 1
fi

"$repo_root/build/AI Reviewer.app/Contents/MacOS/ai-reviewer-watcher" validate --config "$config_path"
