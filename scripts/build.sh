#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

app_name="AI Reviewer.app"
bundle_id="com.ai-reviewer"
build_root="$repo_root/build"
app_root="$build_root/$app_name"
binary_name="ai-reviewer-watcher"
codesign_identity="${AI_REVIEWER_CODESIGN_IDENTITY:--}"
build_configuration="${AI_REVIEWER_BUILD_CONFIGURATION:-release}"

case "$build_configuration" in
  debug|release) ;;
  *)
    echo "AI_REVIEWER_BUILD_CONFIGURATION must be 'debug' or 'release'." >&2
    exit 2
    ;;
esac

"$repo_root/scripts/preflight.sh" --build

mkdir -p "$build_root"

swift build -c "$build_configuration"
binary_path=$(swift build -c "$build_configuration" --show-bin-path)

if [[ -e "$app_root" ]]; then
  rm -rf -- "$app_root"
fi

mkdir -p "$app_root/Contents/MacOS"
mkdir -p "$app_root/Contents/Resources"
cp "$binary_path/$binary_name" "$app_root/Contents/MacOS/$binary_name"
mkdir -p "$app_root/Contents/Resources/profiles"
cp "$repo_root/profiles/default-review.json" "$app_root/Contents/Resources/profiles/default-review.json"
cp "$repo_root/profiles/default-review-cursor.json" "$app_root/Contents/Resources/profiles/default-review-cursor.json"
cp "$repo_root/Assets/AppIcon.icns" "$app_root/Contents/Resources/AppIcon.icns"

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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --sign "$codesign_identity" "$app_root" >/dev/null
/usr/bin/codesign --verify --deep --strict "$app_root"

echo "Built $app_root ($build_configuration)"
