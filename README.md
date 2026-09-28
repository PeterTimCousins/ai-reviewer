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

### Requirements

- macOS 14 or newer
- Xcode 16 or newer, or matching Xcode Command Line Tools, providing Swift 6
- Git
- one configured review provider:
  - **Codex:** install and authenticate the Codex CLI
  - **Cursor:** install and authenticate Cursor Agent (`agent`), or provide a
    Cursor API key
  - **OpenRouter:** provide `OPENROUTER_API_KEY` or save the key in app settings

The app has no third-party Swift package dependencies. Build-time tools come
from Xcode/macOS, and provider CLIs are runtime dependencies only for the
provider you select.

Check a machine before installation with:

```bash
scripts/preflight.sh --install
scripts/preflight.sh --provider codex # or cursor/openrouter
```

### Fresh-machine installation

```bash
git clone https://github.com/PeterTimCousins/ai-reviewer.git
cd ai-reviewer
cp config/local.example.json config/local.json
```

Edit `config/local.json` for the repository you want to watch, then install:

```bash
scripts/install.sh --config config/local.json
```

The installer performs a release build, ad-hoc signs and verifies the app,
installs it to `~/Applications/AI Reviewer.app`, copies the optional config,
and validates its repository paths, selected provider executable, and provider
authentication. It does not copy provider credentials into the repo. You can
instead omit `--config` and complete setup in the app.

For development, build and run checks with:

```bash
scripts/check.sh
scripts/smoke.sh
```

Then use the development bundle directly:

```bash
scripts/smoke.sh
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher materialize-head --config config/local.json
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher review-head --config config/local.json
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher review-once --config config/local.json
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher status --config config/local.json
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher logs --config config/local.json
```

`config/local.json` is ignored by Git. `config/example.json` is safe for public
use and contains placeholder paths only.

### CLI control plane

The same `ai-reviewer-watcher` binary is the primary automation and setup
surface. Run `ai-reviewer-watcher --help` for the complete command list. Common
operations include:

```bash
BIN="$HOME/Applications/AI Reviewer.app/Contents/MacOS/ai-reviewer-watcher"
CONFIG="$HOME/Library/Application Support/com.ai-reviewer/config.json"

"$BIN" status --config "$CONFIG"
"$BIN" status --config "$CONFIG" --json
"$BIN" logs --config "$CONFIG"
"$BIN" watcher --config "$CONFIG" start
"$BIN" watcher --config "$CONFIG" stop
"$BIN" reviews --config "$CONFIG" list failed
"$BIN" reviews --config "$CONFIG" list all --json --limit 100 --offset 0
"$BIN" reviews --config "$CONFIG" show <commit-sha>
"$BIN" reviews --config "$CONFIG" show <commit-sha> --json
"$BIN" reviews --config "$CONFIG" rerun <commit-sha>
"$BIN" reviews --config "$CONFIG" queue-pending
"$BIN" reviews --config "$CONFIG" reconcile
"$BIN" engine --config "$CONFIG" set codex
"$BIN" models --config "$CONFIG" set gpt-5.6-terra --effort medium
"$BIN" models --config "$CONFIG" set gpt-5.6-sol --effort high --agent workflow
"$BIN" config --config "$CONFIG" set maxParallelReviews 4
"$BIN" config --config "$CONFIG" restore-backup
"$BIN" instruction-set --config "$CONFIG" export /tmp/reviewer-instructions.json
"$BIN" app --config "$CONFIG" tab logs
```

`config show` and `config get` redact secrets unless `--show-secrets` is passed.
CLI mutations validate the decoded config and model-specific Codex effort,
write atomically, retain the previous file as `config.json.cli-backup`, and tell
the running app to reload so stale GUI fields cannot overwrite terminal changes.
The `app` command can show, refresh, quit, or switch the running app between the
Reviews, Logs, Settings, and Instruction Set tabs.

Terminal review queries are ledger-first, so completed, failed, and skipped
records remain available beyond the configured recent-history sweep. `--json`
list output is metadata-only and supports `--limit` and `--offset`; this avoids
opening thousands of historical artifacts. `reviews show --json` includes the
resolved verdict and findings. Bounded list enrichment is available with
`--json --details --limit <count>` for counts up to 100.

Review profiles live under `profiles/`. A blank `reviewProfilePath` uses the
bundled default profile (`default-review.json`) regardless of provider. To use a
specific profile, set `reviewProfilePath` to an absolute path or choose a JSON
profile in the settings window. Private repo-specific profiles can live under
`profiles/local/` (git-ignored) and be selected in the settings file picker.

Engine-specific behavior is now configured in the new **Instruction Set** tab. Use
that tab to set the review engine, per-engine default model, and per-agent model
and prompt overrides. Codex model rows also include a model-aware reasoning-effort
selector. Supported effort values and defaults are loaded from Codex's
`models_cache.json`, so changing models cannot carry an unsupported effort label
into the next review. Ultra is deliberately excluded because it delegates to
native Codex subagents, while AI Reviewer already owns that orchestration layer.
These overrides are stored in the main app config so you no
longer need separate `default-review-cursor.json` or cursor-specific profile
files to switch engines.

Codex review subprocesses explicitly disable native multi-agent delegation because
AI Reviewer already owns the specialist orchestration. Each specialist therefore
runs at its selected effort and completes its assigned pass directly, without
creating another layer of Codex agents.

Set `aiProvider` to `cursor` (or choose **Cursor (Composer 2.5)** in the
Instruction Set tab)
to run reviews through the Cursor Agent CLI instead of Codex. The app still
materializes bundles and keeps the AI away from the live repository; only the
executor and bundled instruction profile change.

Set `aiProvider` to `openrouter` (or choose **OpenRouter** in the Instruction Set
tab) to run the same specialist review passes through OpenRouter's chat
completions API. The default OpenRouter model is `deepseek/deepseek-v4-pro`.
Provide `openRouterAPIKey` in local app config or launch the app with
`OPENROUTER_API_KEY` set.

Open the manager window with:

```bash
open build/AI\ Reviewer.app
```

Use **Start** and **Stop** in the manager window to run the watcher inside the
app process. Closing the window leaves an active watcher running; reopen the
window from the app menu, status item, or Dock icon
when the Dock icon is enabled.
Enable **Watch all local worktrees for this repository** to have the watcher
poll every checkout returned by `git worktree list` for the configured
repository. Worktrees are local-only checkout directories; the review ledger is
still shared by commit SHA, so the same commit is not reviewed twice if it
appears in more than one worktree.

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
is also bounded before buffering by the active `maxDiffBytes` value: the app
setting overrides the review profile default when present. Snapshot content is
capped again in aggregate by `maxPromptSnapshotBytes` before being embedded in
specialist prompts; the default is 150000 bytes.

AI scratch runs under `ai-runs` are transient and removed after each
review subprocess finishes. Legacy `codex-runs` directories are trimmed too.
Startup/review cleanup also trims old scratch and bundle
directories according to `maxCodexRunCacheEntries` and `maxBundleCacheEntries`,
and abandoned active-run markers stop protecting scratch directories after the
configured review timeout plus a short grace period.
Defaults keep no scratch runs and the latest 200 bundles.

Validation accepts normal Git worktrees, including linked `git worktree`
checkouts, and creates the configured reports directory if it does not exist.
When `watchAllWorktrees` is enabled, validation reports how many local worktrees
are currently discovered for the configured repository.

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

Pass `--no-build` only when a verified `build/AI Reviewer.app` already exists.
Builds default to release mode; set `AI_REVIEWER_BUILD_CONFIGURATION=debug`
when you specifically need a debug bundle.

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
controls how many specialist agents may run at once inside one commit
review.

The **Logs** view tails the watcher log from
`~/Library/Logs/com.ai-reviewer/watcher.log`.

The **Settings** view keeps common project and automation choices visible, and
puts lower-level paths and developer actions behind **Show Advanced**. It
covers:

- watched repository
- reports path inside that repository
- Review profile path
- review engine (Codex, Cursor/Composer 2.5, or OpenRouter)
- max concurrent commit reviews
- max agents per review
- start watching when app opens
- hide Dock icon
- launch at login
- cache path, Codex home, Codex model, Cursor home, Cursor model, OpenRouter
  model/API key, state path, polling, history, retry, timeout, cache retention,
  max diff bytes, and snapshot limits in Advanced
- materialize/review bundle development actions in Advanced
- watcher enabled/disabled and recent review state

## Review Profiles

A review profile is a JSON file that defines:

- ignored paths, such as generated report folders
- default maximum reviewable diff bytes, overridden by the app-level
  `maxDiffBytes` setting when present
- global review instructions
- optional `provider` (`codex`, `cursor`, or `openrouter`) for compatibility with
  legacy profile metadata only; engine selection is configured in the Instruction
  Set section
- specialist agents, categories, optional model overrides, and conditional
  activation rules

AI Reviewer copies the active profile into each local bundle as
`review-profile.json`. Instruction-set overrides from the config are merged on top
so you can keep profiles engine-agnostic. Specialist runs receive the profile
instructions through prompts while their working directory remains the local
bundle.

Bundled profiles:

- `profiles/default-review.json`: general-purpose enterprise review with
  correctness, security, data integrity, contract, workflow, resilience,
  frontend, and test specialists (used by both engines)
