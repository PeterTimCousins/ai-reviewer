#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/preflight.sh [--build|--install|--provider codex|cursor|openrouter]

Checks the tools required to build, install, or run the selected review provider.
USAGE
}

mode="build"
provider=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build|--install)
      mode="${1#--}"
      shift
      ;;
    --provider)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      provider="$2"
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

[[ "$(uname -s)" == "Darwin" ]] || { echo "AI Reviewer requires macOS." >&2; exit 1; }
command -v git >/dev/null || { echo "Missing Git. Install Xcode Command Line Tools with: xcode-select --install" >&2; exit 1; }
[[ -x /usr/bin/sandbox-exec ]] || { echo "Missing /usr/bin/sandbox-exec; this macOS version cannot run sandboxed reviews." >&2; exit 1; }

if [[ "$mode" == "build" || "$mode" == "install" ]]; then
  command -v xcode-select >/dev/null || { echo "Missing xcode-select." >&2; exit 1; }
  xcode-select -p >/dev/null 2>&1 || { echo "Install Xcode Command Line Tools with: xcode-select --install" >&2; exit 1; }
  command -v swift >/dev/null || { echo "Missing Swift 6. Install Xcode 16 or newer." >&2; exit 1; }
  command -v codesign >/dev/null || { echo "Missing codesign." >&2; exit 1; }
  command -v ditto >/dev/null || { echo "Missing ditto." >&2; exit 1; }
  swift_version=$(swift --version 2>&1)
  swift_major=$(printf '%s\n' "$swift_version" | sed -n 's/.*Apple Swift version \([0-9][0-9]*\).*/\1/p' | head -1)
  [[ -n "$swift_major" && "$swift_major" -ge 6 ]] || { echo "Swift 6 or newer is required." >&2; exit 1; }
fi

find_executable() {
  local name="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  echo "Missing $name." >&2
  return 1
}

case "$provider" in
  "") ;;
  codex)
    find_executable "Codex CLI (install and authenticate Codex first)" \
      "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex >/dev/null
    ;;
  cursor)
    find_executable "Cursor Agent CLI (install it from Cursor and authenticate first)" \
      "$HOME/.local/bin/agent" /opt/homebrew/bin/agent /usr/local/bin/agent >/dev/null
    ;;
  openrouter)
    [[ -n "${OPENROUTER_API_KEY:-}" ]] || { echo "OPENROUTER_API_KEY is not set." >&2; exit 1; }
    ;;
  *)
    echo "Unsupported provider: $provider" >&2
    exit 2
    ;;
esac

echo "Preflight passed ($mode${provider:+, provider: $provider})."
