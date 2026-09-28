#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

command -v python3 >/dev/null || { echo "Missing python3, required for JSON checks." >&2; exit 1; }

for script in scripts/*.sh; do
  bash -n "$script"
done

python3 -m json.tool config/example.json >/dev/null
python3 -m json.tool config/local.example.json >/dev/null
python3 -m json.tool profiles/default-review.json >/dev/null
python3 -m json.tool profiles/default-review-cursor.json >/dev/null

AI_REVIEWER_BUILD_CONFIGURATION=release scripts/build.sh
app="build/AI Reviewer.app"
binary="$app/Contents/MacOS/ai-reviewer-watcher"

[[ -x "$binary" ]]
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$app"
"$binary" --help >/dev/null

echo "All checks passed."
