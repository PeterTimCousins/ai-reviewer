# Architecture

## Goals

- Keep Codex away from the live repository on protected or removable storage.
- Use one stable macOS permission identity for repository access.
- Make review execution auditable, queue based, and bounded.
- Avoid Full Disk Access for Codex and generic shell tools.
- Prevent duplicate app instances and duplicate watcher loops.

## Process Boundary

AI Reviewer owns external repository access. Codex only receives a local review
bundle and runs with:

- `env -i`
- scratch `HOME`
- scratch `TMPDIR`
- explicit `CODEX_HOME` for auth
- minimal `PATH`
- `codex --ask-for-approval never exec`
- `--sandbox read-only`
- `--ephemeral`
- `--ignore-user-config`
- `--ignore-rules`

Review instructions are supplied by AI Reviewer profiles. The app reads a
profile JSON file, materializes that profile into the local bundle, and passes
the relevant profile instructions to each Codex subprocess. Codex does not read
repo-local agent files or scripts from the watched repository.

## Review Flow

1. Run the AI Reviewer watcher inside the app process, or use the foreground
   CLI helper for development.
2. Poll the configured repository HEAD from the AI Reviewer process.
3. Walk recent commits and skip already reviewed, bypassed, merge, empty, and
   oversized commits.
4. Materialize a bundle under `~/Library/Caches/com.ai-reviewer/bundles/<sha>/`.
5. Copy the active review profile into the bundle as `review-profile.json`.
6. Run Codex specialists from the profile against the bundle, not the live repo.
7. Write the final report locally as `codex-review.md`.
8. Copy the report back to `<repoPath>/<reportsPath>/`.
9. Record the SHA in local state.

## Current Implementation Milestone

Build a minimal app plus foreground CLI that:

- Loads a supplied config path.
- Validates repository and report paths.
- Reads `HEAD` and `.git/logs/HEAD`.
- Prints the detected repo status.
- Starts and stops an app-owned polling watcher from the settings window.
- Registers and unregisters the app as a macOS login item from the settings
  window.
- Starts the watcher automatically when the app opens if
  `startWatcherOnLaunch` is enabled.
- Hides the Dock icon if `hideDockIcon` is enabled, while keeping the status
  item available.
- Runs a foreground `--watch` polling loop for CLI development. Startup HEAD
  reconciliation is controlled by `reviewCurrentHeadOnStartup`.
- Reconciles pending commits by walking recent history up to `sweepDepth`,
  skipping already reviewed SHAs, merge commits, and `[skip-review]` or
  `[no-review]` commit messages. Failed SHAs are retried only after
  `retryFailedAfterSeconds`.
- Materializes HEAD into a local cache bundle.
- Runs the configured review profile against a local bundle using the stripped
  environment and read-only sandbox. Profile agents run concurrently up to
  `maxParallelReviews`, then findings are merged deterministically in profile
  order.
- Copies successful reports back through AI Reviewer and records reviewed or
  failed SHAs in local state.

## Concrete Implementation Plan

1. Keep AI Reviewer as the only process that opens the watched repository on
   removable storage.
2. Build and install a stable app bundle at `~/Applications/AI Reviewer.app`
   with bundle identifier `com.ai-reviewer`; use a real signing identity before
   relying on persistent TCC permissions across rebuilds.
3. Poll `.git/logs/HEAD` first, then replace or augment that with FSEvents from
   the app/helper once the core app flow is stable.
4. Store state under `~/Library/Application Support/com.ai-reviewer/`, including
   reviewed SHAs, failed SHAs, last seen HEAD, and last output paths.
   The same app-support directory stores lock files for single-instance and
   watcher-loop ownership.
5. Materialize bundles under `~/Library/Caches/com.ai-reviewer/bundles/<sha>/`
   containing only commit metadata, capped diffs, and capped changed-file
   snapshots. Do not include absolute watched-repo paths in bundles that Codex
   will read.
6. Run Codex from the bundle directory with `env -i`, scratch `HOME`, scratch
   `TMPDIR`, explicit `CODEX_HOME`, minimal `PATH`, read-only sandbox,
   ephemeral execution, ignored user config, and ignored repo rules.
7. Write Codex output to the local cache first as `codex-review.md`, then have
   AI Reviewer copy the final report back to the configured repo reports path.
8. Define review behavior through JSON profiles with global instructions,
   specialist agents, model overrides, ignore paths, and size gates.
9. Keep the settings UI thin over the same app-owned operations used by the
   CLI and menu-bar controls.
10. Keep watcher lifecycle logs under `~/Library/Logs/com.ai-reviewer/` so
   validation does not require Accessibility, AppleScript, or UI automation.

## Public App Roadmap

The app now has a basic settings window. It should evolve toward a menu-bar
utility, with the settings UI remaining thin over the same operations used by
the CLI:

- choose watched repository with `NSOpenPanel`
- configure reports path, cache path, Codex home, poll interval, and parallelism
- choose a review profile JSON file
- validate permissions and Git status
- materialize HEAD and run a local-bundle Codex review
- run the one-shot review workflow with copy-back and state recording
- start and stop the app-owned watcher
- register and unregister the app as a macOS login item
- hide the Dock icon for menu-bar-only operation
- keep a menu bar status item available after the settings window is closed
- open cache and log locations
- show last seen commit, last materialized bundle, and recent errors

Picking the repository through a native open panel is important because it gives
macOS a clear user-intent signal for removable volume access.
