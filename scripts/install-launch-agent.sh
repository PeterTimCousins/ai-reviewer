#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/install-launch-agent.sh [--no-load] [--config <path>] [--app <path>]

Installs a launchd user agent that keeps AI Reviewer running in foreground
watch mode. launchd starts the app executable directly; AI Reviewer is the
process that reads the configured repository.

Experimental: use this only after validating the installed app can access the
chosen repository through the intended macOS permission flow.
USAGE
}

load_agent=1
config_path="${AI_REVIEWER_CONFIG:-${HOME}/Library/Application Support/com.ai-reviewer/config.json}"
app_path="${AI_REVIEWER_APP:-${HOME}/Applications/AI Reviewer.app}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-load)
      load_agent=0
      shift
      ;;
    --config)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      config_path="$2"
      shift 2
      ;;
    --app)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 2
      fi
      app_path="$2"
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

label="com.ai-reviewer.watcher"
plist_path="${HOME}/Library/LaunchAgents/${label}.plist"
support_dir="${HOME}/Library/Application Support/com.ai-reviewer"
log_dir="${HOME}/Library/Logs/com.ai-reviewer"
stdout_log="${log_dir}/watcher.stdout.log"
stderr_log="${log_dir}/watcher.stderr.log"
executable_path="${app_path}/Contents/MacOS/ai-reviewer-watcher"

if [[ ! -x "$executable_path" ]]; then
  echo "Missing executable: $executable_path" >&2
  echo "Run scripts/build.sh and scripts/install.sh first, or pass --app <path>." >&2
  exit 1
fi

if [[ ! -f "$config_path" ]]; then
  echo "Missing config: $config_path" >&2
  echo "Create one from config/local.example.json or pass --config <path>." >&2
  exit 1
fi

cat >&2 <<'WARNING'
Warning: launch agent support is experimental.
Before loading it, validate the installed app flow manually: open AI Reviewer.app,
choose the watched repository in the GUI, save settings, and confirm validation
works from the installed app identity.
WARNING

mkdir -p "$support_dir" "$(dirname "$plist_path")" "$log_dir"

if [[ -f "$plist_path" ]]; then
  backup="${plist_path}.backup.$(date '+%Y%m%d%H%M%S')"
  cp "$plist_path" "$backup"
  echo "Backed up existing plist: $backup"
  launchctl bootout "gui/$(id -u)" "$plist_path" 2>/dev/null || \
    launchctl unload "$plist_path" 2>/dev/null || true
fi

cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${executable_path}</string>
    <string>watch</string>
    <string>--config</string>
    <string>${config_path}</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>

  <key>StandardOutPath</key>
  <string>${stdout_log}</string>
  <key>StandardErrorPath</key>
  <string>${stderr_log}</string>

  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
PLIST

chmod 644 "$plist_path"
plutil -lint "$plist_path" >/dev/null

echo "Installed launch agent config:"
echo "  Label:   $label"
echo "  Plist:   $plist_path"
echo "  Config:  $config_path"
echo "  App:     $app_path"
echo "  Logs:    $stdout_log"
echo "           $stderr_log"

if [[ "$load_agent" -eq 0 ]]; then
  echo "Not loaded (--no-load)."
  exit 0
fi

if launchctl bootstrap "gui/$(id -u)" "$plist_path" 2>/dev/null; then
  echo "Loaded via launchctl bootstrap."
elif launchctl load "$plist_path" 2>/dev/null; then
  echo "Loaded via legacy launchctl load."
else
  echo "Warning: launchctl could not load the agent. Try:"
  echo "  launchctl bootstrap gui/$(id -u) \"$plist_path\""
fi
