# Contributing to Spark

Thank you for helping improve Spark. For a substantial feature or redesign, open an issue first so we can agree on scope. Small fixes can go straight to a pull request.

## Development

Use macOS with Xcode 26.2 or newer. Open `Spark.xcodeproj` and select the Spark scheme. Dependencies are pinned in `Package.resolved`; avoid unrelated dependency upgrades.

```sh
./scripts/lint.sh       # Strict SwiftLint, including tests and Swift scripts
./scripts/check.sh      # Build and run SparkTests, including real PTY tests
```

To apply the repository's formatting and automatic lint fixes:

```sh
./scripts/format.sh
```

SwiftLint 0.65.1 is pinned in `scripts/lint.sh`. The script uses that installed version or downloads the official portable archive into `.build/tools`, verifying its SHA-256. `swift-format` comes with Xcode; SwiftLint remains the enforced CI gate. No baseline hides existing violations.

The test build uses ad-hoc signing and disables the hardened runtime so Sparkle can load. Distribution builds retain Developer ID signing and the hardened runtime.

`SparkUITests` additionally exercises native UI interactions and requires Xcode's UI automation permission on the Mac running it. Run it from Xcode, or use `xcodebuild test -project Spark.xcodeproj -scheme Spark -destination 'platform=macOS' -only-testing:SparkUITests`. CI runs `SparkTests`, compiles the universal Release app, and mounts a DMG to verify its contents; it does not run the UI automation suite.

## Pull requests

- Describe the problem, the resulting behavior, and how you verified it.
- Keep changes focused and follow the existing SwiftUI/AppKit ownership boundaries.
- Add regression coverage for behavior changes involving PTYs, persistence, Git, or agent integration. Use temporary fixtures, never a contributor's real worktrees or agent history.
- For visual changes, include screenshots and check keyboard navigation and Reduce Motion.
- Run lint, relevant tests, and `git diff --check`. Distinguish build/test evidence from manual UI verification.
- Never commit credentials, signing material, private transcripts, or local workspace state.

## Reporting bugs

Include the Spark version or commit, macOS version, CPU architecture, shell, reproduction steps, and expected/actual behavior. For agent integration, also include the CLI version and whether you use an alias or wrapper. Redact private paths and terminal contents from logs and screenshots.

Contributions are licensed under the repository's MIT license. Keep notices for any third-party code or assets you add.
