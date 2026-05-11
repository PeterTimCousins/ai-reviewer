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
   read-only sandboxing, non-interactive approvals, and the configured review
   profile instructions.
5. The app copies the final review report back to the configured reports path.

## Status

This is early-stage software. The current app can:

- build a small macOS app bundle with bundle identifier `com.ai-reviewer`
- open a basic settings window when launched normally
- validate a local JSON config
- start and stop an app-owned repository HEAD watcher from the settings window
- optionally register the app as a macOS login item
- start the watcher when the app opens
- optionally hide the Dock icon
- watch a repository HEAD in the foreground from the CLI
- materialize the current HEAD into a local cache bundle
- run Codex against a local cache bundle with a stripped environment
- run profile-driven specialist reviews from bundled or user-selected JSON
  profiles
- copy completed review reports back to the configured reports directory
- track reviewed, skipped, and failed SHAs in local state

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

Review profiles live under `profiles/`. A blank `reviewProfilePath` uses the
bundled default profile. To use a specific profile, set `reviewProfilePath` to
an absolute path or choose a JSON profile in the settings window. Private
repo-specific profiles can live under ignored `profiles/local/`.

Open the settings window with:

```bash
open build/AI\ Reviewer.app
```

Use **Start Watching** and **Stop Watching** in the settings window to run the
watcher inside the app process. Closing the settings window leaves an active
watcher running; reopen the window from the app menu, status item, or Dock icon
when the Dock icon is enabled.

Enable **Launch AI Reviewer at login** to register the app with macOS Login
Items. **Start watching when app opens** is enabled by default so the watcher
resumes automatically when the app is opened manually or by macOS at login.
**Hide Dock icon** is also enabled by default so the app behaves like a menu-bar
utility. If no repository is configured yet, the settings window opens instead
of failing invisibly in the background.

AI Reviewer uses local lock files under
`~/Library/Application Support/com.ai-reviewer/` to prevent accidental duplicate
GUI app instances and duplicate watcher loops.

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

`review-head` materializes the current HEAD, then runs the configured review
profile against that bundle.

`review-once` materializes HEAD, runs the configured review profile, copies
`codex-review.md` back to the configured reports path, and records the SHA in
local state. Already reviewed SHAs are skipped.

`watch` runs in the foreground and reviews pending commits when HEAD changes.
Pending commits are discovered by walking up to `sweepDepth` recent commits,
skipping already reviewed SHAs, merge commits, and commit messages containing
`[skip-review]` or `[no-review]`. Startup reconciliation only runs when
`reviewCurrentHeadOnStartup` is enabled in config. Failed reviews are retried
after `retryFailedAfterSeconds`; the default is one hour. The watcher also
checks for due failed-review retries while HEAD is stable.

Codex runs are terminated after `codexTimeoutSeconds`; the default is 30
minutes. File snapshots are capped individually by `maxSnapshotBytes` during
bundle materialization, and capped again in aggregate by
`maxPromptSnapshotBytes` before being embedded in specialist prompts.

## Planned Runtime Locations

- App: `~/Applications/AI Reviewer.app`
- Config: `~/Library/Application Support/com.ai-reviewer/config.json`
- Bundles/cache: `~/Library/Caches/com.ai-reviewer/`
- State: `~/Library/Application Support/com.ai-reviewer/state.json`
- Locks: `~/Library/Application Support/com.ai-reviewer/*.lock`
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
stopping the app-owned watcher, controlling login-item registration, opening
the cache and log folders, and staying available from the macOS menu bar when
the settings window is closed.

The intended product shape is a menu-bar app that owns the watcher lifecycle.
The settings UI currently covers:

- watched repository
- reports path inside that repository
- cache path
- Codex home path
- Codex model
- Review profile path
- state path
- poll interval
- sweep depth
- retry failed seconds
- Codex timeout seconds
- max parallel reviews/profile agents
- max prompt snapshot bytes
- start watching when app opens
- hide Dock icon
- review pending commits on watcher startup
- launch at login
- watcher enabled/disabled and recent review state

## Review Profiles

A review profile is a JSON file that defines:

- ignored paths, such as generated report folders
- maximum reviewable diff bytes
- global review instructions
- specialist agents, categories, optional model overrides, and conditional
  activation rules

AI Reviewer copies the active profile into each local bundle as
`review-profile.json`. Specialist Codex runs receive the profile instructions
through prompts while their working directory remains the local bundle.

Bundled profiles:

- `profiles/default-review.json`: general-purpose enterprise review with
  correctness, security, data integrity, contract, workflow, resilience,
  frontend, and test specialists
