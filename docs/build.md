# Build Notes

This repo is scaffolded as a Swift macOS utility, but the local machine
currently has a Command Line Tools mismatch:

- Swift compiler: `swiftlang-6.2.0.19.9`
- macOS SDK Swift interfaces: `swiftlang-6.2.0.17.14`

That causes both `swift build` and direct `swiftc` compilation to fail before
the app code is compiled. Fix by reinstalling/updating Xcode Command Line Tools
or installing full Xcode, then rerun:

```bash
scripts/build.sh
scripts/smoke.sh
```

The repo structure and source are still committed so implementation can proceed
once the local toolchain is repaired.
