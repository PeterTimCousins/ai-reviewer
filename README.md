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
- start and stop an app-owned repository HEAD watcher from the settings window
- watch a repository HEAD in the foreground from the CLI
- materialize the current HEAD into a local cache bundle
- run Codex against a local cache bundle with a stripped environment
- copy completed review reports back to the configured reports directory
- track reviewed and failed SHAs in local state

## Quick Start

```bash
scripts/build.sh
cp config/local.example.json config/local.json
```

Edit `config/local.json`, then run:

```bash
scripts/smoke.sh
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher materialize-head --config config/local.json
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher review-head --config config/local.json
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher review-once --config config/local.json
```

`config/local.json` is ignored by Git. `config/example.json` is safe for public
use and contains placeholder paths only.

Open the settings window with:

```bash
open build/AI\ Reviewer.app
```

Use **Start Watching** and **Stop Watching** in the settings window to run the
watcher inside the app process. Closing the settings window leaves an active
watcher running; reopen the window from the app menu or Dock icon.

## Commands

```bash
ai-reviewer-watcher validate --config <path>
ai-reviewer-watcher watch --config <path>
ai-reviewer-watcher materialize-head --config <path>
ai-reviewer-watcher run-codex --config <path> --bundle <sha-or-path>
ai-reviewer-watcher review-head --config <path>
ai-reviewer-watcher review-once --config <path>
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

`run-codex` writes:

- `codex-review.md`
- `codex.log`

`review-head` materializes the current HEAD, then runs Codex against that
bundle.

`review-once` materializes HEAD, runs Codex, copies `codex-review.md` back to
the configured reports path, and records the SHA in local state. Already
reviewed SHAs are skipped.

`watch` runs in the foreground and calls `review-once` when HEAD changes. It
only reconciles the current HEAD at startup when `reviewCurrentHeadOnStartup` is
enabled in config.

## Planned Runtime Locations

- App: `~/Applications/AI Reviewer.app`
- Config: `~/Library/Application Support/com.ai-reviewer/config.json`
- Bundles/cache: `~/Library/Caches/com.ai-reviewer/`
- State: `~/Library/Application Support/com.ai-reviewer/state.json`
- Logs: `~/Library/Logs/com.ai-reviewer/watcher.log`

Install the built app bundle with:

```bash
scripts/install.sh
```

## Permission Policy

AI Reviewer should be the only process that receives access to the watched
repository. Codex should not be granted Full Disk Access and should not need
direct access to removable volumes or protected folders.

Codex subprocesses run from local bundles with:

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

The app passes `--cd <bundle>` and `--skip-git-repo-check`, so Codex does not
need a Git checkout or direct access to the watched repository.

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
running a HEAD review, running the one-shot review workflow, starting and
stopping the app-owned watcher, opening the cache and log folders, and staying
available from the macOS menu bar when the settings window is closed.

The intended product shape is a menu-bar app that owns the watcher lifecycle.
The settings UI currently covers:

- watched repository
- reports path inside that repository
- cache path
- Codex home path
- Codex model
- state path
- poll interval
- max parallel reviews
- review current HEAD on watcher startup
- watcher enabled/disabled and recent review state

The repository picker should use a native macOS open panel so users explicitly
grant the app access to the watched repo.
