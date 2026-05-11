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

Skeleton only. The first implementation target is a foreground Swift executable
that can load config and validate paths. The next target is a menu-bar app or
login item wrapper with a commit review queue.

## Planned Runtime Locations

- App: `~/Applications/AI Reviewer.app`
- Config: `~/Library/Application Support/com.ai-reviewer/config.json`
- Bundles/cache: `~/Library/Caches/com.ai-reviewer/`
- Logs: `~/Library/Logs/com.ai-reviewer/`

## Permission Policy

Allow the AI Reviewer app to access only the repository/removable volume it
needs to watch. Do not grant Full Disk Access to Codex. Deny unrelated prompts
such as Media Library, Photos, Contacts, Calendar, Camera, or Microphone.
