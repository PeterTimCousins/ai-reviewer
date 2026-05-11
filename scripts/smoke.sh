#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

"$repo_root/build/AI Reviewer.app/Contents/MacOS/ai-reviewer-watcher" --config config/example.json --once
