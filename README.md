# AI Reviewer

AI Reviewer is a macOS utility for running background AI code reviews without
granting the AI CLI broad disk permissions.

The intended model is:

1. A stable macOS app/helper watches a configured Git repository.
2. The app is the only process granted access to that repository, including
   removable volumes.
3. For each commit, the app materializes a local review bundle containing only
   commit metadata, diffs, and capped changed-file snapshots.
4. Codex or Cursor Agent runs only against that local bundle with a stripped environment,
   read-only sandboxing, non-interactive approvals, and the configured review
   profile instructions.
5. The app copies the final review report back to the configured reports path.

## Status

This is early-stage software. The current app can:

- build a small macOS app bundle with bundle identifier `com.ai-reviewer`
- open a manager window when launched normally
- validate a local JSON config
- start and stop an app-owned repository HEAD watcher from the manager window
- optionally register the app as a macOS login item
- start the watcher when the app opens
- optionally hide the Dock icon
- show recent Git commit history with completed, failed, skipped, running, and
  pending review state
- load completed review output and watcher logs in the app
- manually queue a rerun for a selected commit
- watch a repository HEAD in the foreground from the CLI
- materialize the current HEAD into a local cache bundle
- run Codex or Cursor Agent against a local cache bundle with a stripped environment
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
bundled default profile for the selected review engine (`default-review.json` for
Codex, `default-review-cursor.json` for Cursor/Composer 2.5). To use a specific
profile, set `reviewProfilePath` to an absolute path or choose a JSON profile in
the settings window. Private repo-specific profiles can live under ignored
`profiles/local/`.

Set `aiProvider` to `cursor` (or choose **Cursor (Composer 2.5)** in Settings)
to run reviews through the Cursor Agent CLI instead of Codex. The app still
materializes bundles and keeps the AI away from the live repository; only the
executor and bundled instruction profile change.

Open the manager window with:

```bash
open build/AI\ Reviewer.app
```

Use **Start** and **Stop** in the manager window to run the watcher inside the
app process. Closing the window leaves an active watcher running; reopen the
window from the app menu, status item, or Dock icon
when the Dock icon is enabled.

Enable **Launch AI Reviewer at login** to register the app with macOS Login
Items. **Start watching when app opens** is enabled by default so the watcher
resumes automatically when the app is opened manually or by macOS at login.
**Hide Dock icon** is also enabled by default so the app behaves like a menu-bar
utility. If no repository is configured yet, the settings window opens instead
of failing invisibly in the background.

AI Reviewer uses local lock files under
`~/Library/Application Support/com.ai-reviewer/` to prevent accidental duplicate
GUI app instances and duplicate watcher loops. The foreground CLI watcher and
GUI watcher share the same watcher lock.

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

- `review.md`
- `ai.log`

Legacy Codex bundles may still contain `codex-review.md` and `codex.log`; the app
reads those when present.

`review-head` materializes the current HEAD, then runs the configured review
profile against that bundle.

`review-once` materializes HEAD, runs the configured review profile, copies
`review.md` back to the configured reports path, and records the SHA in
local state. Already reviewed SHAs are skipped.

`watch` runs in the foreground and reviews pending commits when HEAD changes.
Pending commits are discovered by walking up to `sweepDepth` recent commits,
skipping already reviewed SHAs, merge commits, and commit messages containing
`[skip-review]` or `[no-review]`. Commits that deterministically exceed the
profile diff limit are recorded as skipped instead of retried forever. Startup
always reconciles the current HEAD if it has no completed, failed, or skipped
ledger entry. Full pending-commit catch-up on startup only runs when
`reviewCurrentHeadOnStartup` is enabled in config.
Failed reviews are retried after `retryFailedAfterSeconds`; the default is one
hour. The watcher also checks for due failed-review retries while HEAD is
stable.

Codex runs are terminated after `codexTimeoutSeconds`; the default is 30
minutes. File snapshots are capped individually by `maxSnapshotBytes` during
bundle materialization, with Git output bounded before buffering. Diff output
is also bounded before buffering when a profile sets `maxDiffBytes`. Snapshot
content is capped again in aggregate by `maxPromptSnapshotBytes` before being
embedded in specialist prompts.

AI scratch runs under `ai-runs` are transient and removed after each
review subprocess finishes. Legacy `codex-runs` directories are trimmed too.
Startup/review cleanup also trims old scratch and bundle
directories according to `maxCodexRunCacheEntries` and `maxBundleCacheEntries`.
Defaults keep no scratch runs and the latest 200 bundles.

Validation accepts normal Git worktrees, including linked `git worktree`
checkouts, and creates the configured reports directory if it does not exist.

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

- a per-run `sandbox-exec` profile that only allows reads from the local bundle,
  narrowed per-run Codex auth/config, scratch directories, and required system
  tool/runtime paths
- `env -i`
- scratch `HOME`
- scratch `TMPDIR`
- per-run `CODEX_HOME` containing copied auth/config material, not the user's
  full Codex home
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

## GUI

The app opens to a review manager rather than a raw settings form. The
**Reviews** view shows recent Git commits from the watched repository and joins
them with the local state ledger so each commit is marked completed, failed,
skipped, running, or pending. Selecting a completed review loads the review
text in the app; selecting a failed or skipped review shows the recorded reason.
The selected commit can be manually rerun, which intentionally clears that
commit's reviewed/failed/skipped ledger entries before running the review again.
Manual reruns enter an in-app queue. `maxParallelCommitReviews` controls how
many whole commit reviews may run at once; the default is `1`. `maxParallelReviews`
controls specialist-agent concurrency inside one commit review.

The **Logs** view tails the watcher log from
`~/Library/Logs/com.ai-reviewer/watcher.log`.

The **Settings** view keeps common project and automation choices visible, and
puts lower-level paths and developer actions behind **Show Advanced**. It
covers:

- watched repository
- reports path inside that repository
- Review profile path
- review engine (Codex or Cursor/Composer 2.5)
- max concurrent commit reviews
- max agents per review
- start watching when app opens
- hide Dock icon
- launch at login
- cache path, Codex home, Codex model, Cursor home, Cursor model, state path, polling, history, retry,
  timeout, cache retention, and snapshot limits in Advanced
- materialize/review bundle development actions in Advanced
- watcher enabled/disabled and recent review state

## Review Profiles

A review profile is a JSON file that defines:

- ignored paths, such as generated report folders
- maximum reviewable diff bytes
- global review instructions
- optional `provider` (`codex` or `cursor`) to match the selected review engine
- specialist agents, categories, optional model overrides, and conditional
  activation rules

AI Reviewer copies the active profile into each local bundle as
`review-profile.json`. If a profile sets `provider`, it must match the configured
review engine. Specialist runs receive the profile instructions through prompts
while their working directory remains the local bundle.

Bundled profiles:

- `profiles/default-review.json`: general-purpose enterprise review with
  correctness, security, data integrity, contract, workflow, resilience,
  frontend, and test specialists (Codex)
- `profiles/default-review-cursor.json`: same specialist layout tuned for Cursor
  Agent with Composer 2.5
