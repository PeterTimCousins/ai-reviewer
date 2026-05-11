# Build Notes

This repo is scaffolded as a Swift macOS utility, but the local machine
currently has a Command Line Tools mismatch:

- Swift compiler: `swiftlang-6.2.0.19.9`
- macOS SDK Swift interfaces: `swiftlang-6.2.0.17.14`

That causes both `swift build` and direct `swiftc` compilation to fail before
the app code is compiled.

Until the local Swift toolchain is repaired, `scripts/build.sh` automatically
falls back to `Sources/AIReviewerWatcherObjC/main.m`, which builds with
Objective-C Foundation and `clang`. The fallback preserves the first milestone
behavior and produces:

```text
build/AI Reviewer.app
build/AI Reviewer.app/Contents/MacOS/ai-reviewer-watcher
```

SwiftPM failure details are captured in `build/swiftpm-build.log` so normal
fallback builds stay readable.

The bundle identifier is `com.ai-reviewer`. The default signature is ad-hoc
because no project signing identity is configured. For TCC permissions that are
more stable across rebuilds, set a real signing identity:

```bash
AI_REVIEWER_CODESIGN_IDENTITY="Developer ID Application: Example" scripts/build.sh
```

To use Swift again, reinstall or update Xcode Command Line Tools, or install
full Xcode, then rerun:

```bash
scripts/build.sh
scripts/smoke.sh
```

`scripts/install.sh` copies the built bundle to `~/Applications/AI Reviewer.app`.
