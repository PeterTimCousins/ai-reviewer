# AI Reviewer

AI Reviewer is a macOS utility for running background AI code reviews without
granting the AI CLI broad disk permissions.

The intended model is:

1. A stable macOS app/helper watches a configured Git repository.
2. The app is the only process granted access to that repository, including
   removable volumes.
3. For each commit, the app materializes a local review bundle containing only
   commit metadata, diffs, and capped changed-file snapshots.
4. Codex runs only against that local bundle with a stripped environment,
   read-only sandboxing, and non-interactive approvals.
5. The app copies the final review report back to the configured reports path.

## Status

This is early-stage software. The current app can:

- build a small macOS app bundle with bundle identifier `com.ai-reviewer`
- open a basic settings window when launched normally
- validate a local JSON config
- watch a repository HEAD in the foreground
- materialize the current HEAD into a local cache bundle

Codex execution and report copying are intentionally not wired in yet.

## Quick Start

```bash
scripts/build.sh
cp config/local.example.json config/local.json
```

Edit `config/local.json`, then run:

```bash
scripts/smoke.sh
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher materialize-head --config config/local.json
```

`config/local.json` is ignored by Git. `config/example.json` is safe for public
use and contains placeholder paths only.

Open the settings window with:

```bash
open build/AI\ Reviewer.app
```

## Commands

```bash
ai-reviewer-watcher validate --config <path>
ai-reviewer-watcher watch --config <path>
ai-reviewer-watcher materialize-head --config <path>
```

`materialize-head` writes to:

```text
~/Library/Caches/com.ai-reviewer/bundles/<sha>/
```

The bundle contains:

- `bundle.json`
- `commit.txt`
- `diff.patch`
- `changed-files.json`
- capped snapshots under `snapshots/`

## Planned Runtime Locations

- App: `~/Applications/AI Reviewer.app`
- Config: `~/Library/Application Support/com.ai-reviewer/config.json`
- Bundles/cache: `~/Library/Caches/com.ai-reviewer/`
- Logs: `~/Library/Logs/com.ai-reviewer/`

Install the built app bundle with:

```bash
scripts/install.sh
```

## Permission Policy

AI Reviewer should be the only process that receives access to the watched
repository. Codex should not be granted Full Disk Access and should not need
direct access to removable volumes or protected folders.

When Codex execution is added, subprocesses should run from local bundles with:

- `env -i`
- scratch `HOME`
- scratch `TMPDIR`
- explicit `CODEX_HOME`
- minimal `PATH`
- `codex --ask-for-approval never exec`
- `--sandbox read-only`
- `--ephemeral`
- `--ignore-user-config`
- `--ignore-rules`

Deny unrelated macOS permission prompts such as Media Library, Photos, Contacts,
Calendar, Camera, and Microphone.

## Signing

By default the app is ad-hoc signed. For a permission identity that is more
stable across rebuilds, set a real signing identity before building:

```bash
AI_REVIEWER_CODESIGN_IDENTITY="Developer ID Application: Example" scripts/build.sh
```

## GUI Roadmap

The app currently includes a basic settings window for editing the app-support
config, choosing a watched repository, validating settings, materializing HEAD,
and opening the cache folder.

The intended product shape is a menu-bar app. The settings UI should continue
to cover:

- watched repository
- reports path inside that repository
- cache path
- Codex home path
- poll interval
- max parallel reviews
- watcher enabled/disabled

The repository picker should use a native macOS open panel so users explicitly
grant the app access to the watched repo.
