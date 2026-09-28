# Build Notes

This repo builds with SwiftPM and packages the executable into a small macOS app
bundle:

```bash
scripts/build.sh
scripts/smoke.sh
```

Requirements are macOS 14+, Xcode 16 or matching Command Line Tools with Swift
6, and Git. Verify them with `scripts/preflight.sh --build`. The Swift package
has no third-party package dependencies. Codex and Cursor CLIs are runtime
dependencies only when their provider is selected; OpenRouter instead requires
an API key and network access.

The expected output app is:

```text
build/AI Reviewer.app
build/AI Reviewer.app/Contents/MacOS/ai-reviewer-watcher
```

The bundle identifier is `com.ai-reviewer`. The default signature is ad-hoc. For
TCC permissions that are more stable across rebuilds, set a real signing
identity:

```bash
AI_REVIEWER_CODESIGN_IDENTITY="Developer ID Application: Example" scripts/build.sh
```

`scripts/install.sh` performs a fresh release build, verifies the signature, and
installs the bundle to `~/Applications/AI Reviewer.app`. Pass `--config <path>`
to also copy and validate a config at the app-support location used by the
installed app:

```bash
scripts/install.sh --config config/local.json
```

Config validation fails early when the selected provider CLI or authentication
is unavailable, so a fresh installation cannot silently appear ready while its
first review is guaranteed to fail.

Use `scripts/install.sh --no-build` only when the existing bundle has already
been verified. `scripts/check.sh` is the CI/local release gate: it checks shell
syntax and tracked JSON, creates a release app bundle, verifies its plist and
signature, and exercises the binary's help entry point.

Launch the settings window with:

```bash
open build/AI\ Reviewer.app
```

For local testing, copy the ignored config template and edit the paths:

```bash
cp config/local.example.json config/local.json
scripts/smoke.sh
```

The public `config/example.json` intentionally uses placeholder paths.

Run the first local-bundle review with:

```bash
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher review-head --config config/local.json
```

Run the first complete one-shot workflow with state and report copy-back:

```bash
build/AI\ Reviewer.app/Contents/MacOS/ai-reviewer-watcher review-once --config config/local.json
```
