# Build Notes

This repo builds with SwiftPM and packages the executable into a small macOS app
bundle:

```bash
scripts/build.sh
scripts/smoke.sh
```

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

`scripts/install.sh` copies the built bundle to `~/Applications/AI Reviewer.app`.

For local testing, copy the ignored config template and edit the paths:

```bash
cp config/local.example.json config/local.json
scripts/smoke.sh
```

The public `config/example.json` intentionally uses placeholder paths.
