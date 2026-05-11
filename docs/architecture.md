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

After that works, add materialization, review execution, and a menu-bar/login
item wrapper.
