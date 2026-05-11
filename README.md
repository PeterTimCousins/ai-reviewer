# AI Reviewer

AI Reviewer is a small macOS watcher for running background AI code reviews
without granting the AI CLI broad disk permissions.

The intended model is:

1. A stable macOS app/helper watches a configured Git repository.
2. The app is the only process granted access to the external repo/removable
   volume.
3. For each commit, the app materializes a local review bundle containing only
   commit metadata, diffs, and capped changed-file snapshots.
4. Codex runs only against that local bundle with a stripped environment,
   read-only sandboxing, and non-interactive approvals.
5. The app copies the final review report back to the configured reports path.

This repo is intentionally separate from the dropship app so its permission
model, install lifecycle, and review queue can be managed independently.

## Current Status

The first implementation target is a foreground helper that can load config,
validate the watched repository and reports path, and read Git HEAD state.

SwiftPM is currently blocked on this Mac by a Command Line Tools compiler/SDK
mismatch, so `scripts/build.sh` falls back to an Objective-C Foundation helper
that builds with `clang`. The fallback is packaged as a macOS app bundle with:

- Bundle path: `build/AI Reviewer.app`
- Bundle identifier: `com.ai-reviewer`
- Executable: `Contents/MacOS/ai-reviewer-watcher`

By default the app is ad-hoc signed. For a permission identity that survives
rebuilds, set a real local signing identity before building:

```bash
AI_REVIEWER_CODESIGN_IDENTITY="Developer ID Application: Example" scripts/build.sh
```

## Planned Runtime Locations

- App: `~/Applications/AI Reviewer.app`
- Config: `~/Library/Application Support/com.ai-reviewer/config.json`
- Bundles/cache: `~/Library/Caches/com.ai-reviewer/`
- Logs: `~/Library/Logs/com.ai-reviewer/`

## Permission Policy

Allow the AI Reviewer app to access only the repository/removable volume it
needs to watch. Do not grant Full Disk Access to Codex. Deny unrelated prompts
such as Media Library, Photos, Contacts, Calendar, Camera, or Microphone.

## Build And Smoke Test

```bash
scripts/build.sh
scripts/smoke.sh
```

Run the foreground watcher loop with:

```bash
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher --config config/example.json --watch
```

Install the app bundle to the planned stable path with:

```bash
scripts/install.sh
```
