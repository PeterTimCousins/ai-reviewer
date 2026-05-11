#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

app_name="AI Reviewer.app"
bundle_id="com.ai-reviewer"
build_root="$repo_root/build"
app_root="$build_root/$app_name"
binary_name="ai-reviewer-watcher"
fallback_source="$repo_root/Sources/AIReviewerWatcherObjC/main.m"
codesign_identity="${AI_REVIEWER_CODESIGN_IDENTITY:--}"
swiftpm_log="$build_root/swiftpm-build.log"

mkdir -p "$build_root"

if [[ "${AI_REVIEWER_FORCE_FALLBACK:-0}" != "1" ]] && swift build >"$swiftpm_log" 2>&1; then
  mkdir -p "$app_root/Contents/MacOS"
  cp "$repo_root/.build/debug/ai-reviewer-watcher" "$app_root/Contents/MacOS/$binary_name"
  build_mode="swiftpm"
else
  echo "SwiftPM unavailable; falling back to Objective-C clang build. See $swiftpm_log" >&2
  rm -rf "$app_root"
  mkdir -p "$app_root/Contents/MacOS"
  /usr/bin/clang \
    -fobjc-arc \
    -framework Foundation \
    "$fallback_source" \
    -o "$app_root/Contents/MacOS/$binary_name"
  build_mode="objc-fallback"
fi

cat > "$app_root/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$binary_name</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AI Reviewer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSBackgroundOnly</key>
  <true/>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --sign "$codesign_identity" "$app_root" >/dev/null

echo "Built $app_root ($build_mode)"
