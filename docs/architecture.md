# Architecture

## Goals

- Keep Codex away from the live repository on protected or removable storage.
- Use one stable macOS permission identity for repository access.
- Make review execution auditable, queue based, and bounded.
- Avoid Full Disk Access for Codex and generic shell tools.

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

## Review Flow

1. Watch `.git/logs/HEAD` or poll it.
2. Walk recent commits and skip already reviewed, bypassed, merge, empty, and
   oversized commits.
3. Materialize a bundle under `~/Library/Caches/com.ai-reviewer/bundles/<sha>/`.
4. Run Codex specialists against the bundle, not the live repo.
5. Write the final report locally.
6. Copy the report back to `<repoPath>/<reportsPath>/`.
7. Record the SHA in local state and, optionally, the repo review ledger.

## First Implementation Milestone

Build a foreground CLI that:

- Loads `config/example.json` or a supplied config path.
- Validates repository and report paths.
- Reads `HEAD` and `.git/logs/HEAD`.
- Prints the detected repo status.
- Runs a simple `--watch` polling loop that reports HEAD changes.

After that works, add materialization, review execution, and a menu-bar/login
item wrapper.

## Concrete Implementation Plan

1. Keep AI Reviewer as the only process that opens the watched repository on
   removable storage.
2. Build and install a stable app bundle at `~/Applications/AI Reviewer.app`
   with bundle identifier `com.ai-reviewer`; use a real signing identity before
   relying on persistent TCC permissions across rebuilds.
3. Poll `.git/logs/HEAD` first, then replace or augment that with FSEvents from
   the app/helper once the menu-bar/login-item wrapper exists.
4. Store state under `~/Library/Application Support/com.ai-reviewer/`, including
   reviewed SHAs, bypassed SHAs, and in-flight jobs.
5. Materialize bundles under `~/Library/Caches/com.ai-reviewer/bundles/<sha>/`
   containing only commit metadata, capped diffs, and capped changed-file
   snapshots.
6. Run Codex from the bundle directory with `env -i`, scratch `HOME`, scratch
   `TMPDIR`, explicit `CODEX_HOME`, minimal `PATH`, read-only sandbox,
   ephemeral execution, ignored user config, and ignored repo rules.
7. Write Codex output to the local cache first, then have AI Reviewer copy the
   final report back to the configured repo reports path.
8. Add a menu-bar app and login item after the foreground watcher can run one
   review cycle end to end.
