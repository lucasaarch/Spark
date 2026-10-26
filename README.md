# Spark

A little more possible. A native macOS terminal with graphite surfaces, warm amber accents, a quiet tab bar, and room to think.

Built with **SwiftUI + AppKit**, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), and [Sparkle](https://sparkle-project.org). macOS 14 or later. Release builds support Apple Silicon and Intel.

## What works

- Metal rendering with a Core Graphics fallback when a GPU surface is unavailable.
- Real PTY sessions running your account's login shell and shell configuration.
- Persistent tabs and independent windows. Switching tabs keeps the process and scrollback alive.
- 10,000 lines of scrollback, true color, selection, copy/paste, and SwiftTerm's native search.
- Open a folder in a new session. New tabs inherit the active session's reported directory (OSC 7); without shell directory reporting, they inherit its initial directory.
- Focus mode, adjustable monospaced text, and optional Option-as-Meta.
- Confirmation before closing active shells, including when quitting the app.
- Signed Sparkle updates delivered through GitHub Releases.

Spark is intentionally not sandboxed: a local terminal needs to run your tools and access your files. Releases use Apple's hardened runtime and Developer ID signing. Terminal-provided links only open HTTP, HTTPS, and mailto URLs. Remote clipboard protocol services are not opted in.

## Run

Open `Spark.xcodeproj`, select the **Spark** scheme, and run. Use Xcode 26.2 or newer with Swift 6.2 or newer (CI uses Xcode 26.6). Choose your development team for local signing. Dependencies are pinned in `Package.resolved`.

To build and run the integration tests without a signing identity:

```sh
./scripts/check.sh
open .build/DerivedData/Build/Products/Debug/Spark.app
```

This local test build disables the hardened runtime to load the vendor-signed Sparkle framework with an ad-hoc signature. Distribution builds retain the hardened runtime and use Developer ID signing.

The tests exercise real PTY output and termination, session ownership, tab selection, directory inheritance, and terminal environment variables. The `SparkUITests` target additionally exercises native UI interactions and requires Xcode's UI automation permission on the Mac running it. CI runs the integration tests and compiles the universal Release app.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| New tab / window | ⌘T / ⌘N |
| Close tab / window | ⌘W / ⇧⌘W |
| Previous / next tab | ⇧⌘[ / ⇧⌘] |
| Open folder | ⌘O |
| Find | ⌘F |
| Focus mode | ⇧⌘F |
| Larger / smaller / default text | ⌘= / ⌘− / ⌘0 |
| Settings | ⌘, |

## Releases and updates

The updater reads:

```
https://github.com/lucasaarch/Spark/releases/latest/download/appcast.xml
```

The URL starts working after the first successful release. The GitHub releases page itself is not an appcast. Each release contains `Spark-VERSION.zip`, `appcast.xml`, and `SHA256SUMS`.

Configure these **repository Actions secrets** at [Settings → Secrets and variables → Actions](https://github.com/lucasaarch/Spark/settings/secrets/actions):

| Secret | Value |
| --- | --- |
| `CERTIFICATE_P12_BASE64` | Base64 of a `.p12` containing your **Developer ID Application** certificate and private key |
| `CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| `APPLE_TEAM_ID` | Apple Developer team identifier |
| `APPLE_API_KEY_BASE64` | Base64 of the App Store Connect API **Team Key** `.p8` used for notarization |
| `APPLE_API_KEY_ID` | That API key's identifier |
| `APPLE_API_ISSUER_ID` | App Store Connect issuer identifier |
| `SPARKLE_PRIVATE_KEY` | Sparkle Ed25519 private key; **already configured for this repository** |

`GITHUB_TOKEN` is supplied automatically. The release job maps these secrets to environment variables and checks them before building. Keys are decoded only into a temporary directory and removed on exit. Never commit certificates or private keys. Base64 values must be a single line.

The Sparkle public key is committed in `Config/Spark-Info.plist`. Its matching private key is also stored in the original developer Mac's Keychain under account `lucasaarch.Spark`; preserve it for future releases. Do not generate a different key for each release.

After filling the Apple secrets, publish a version:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow validates the stable version tag, runs tests, archives a universal app, signs and exports with Developer ID, submits to Apple, checks acceptance, staples and validates the notarization, signs the update archive with Sparkle, and uploads all assets to a draft release before publishing it. Both bundle versions come from the tag. A release must be newer than the latest published version. No unsigned fallback is published if signing or notarization fails.

If publishing fails after creating a draft, inspect and remove that incomplete draft before rerunning the job. Do not replace an already published version; create a new version tag.

## Project layout

- `Spark/TerminalSession.swift`: owns the terminal view, PTY, shell environment, and process callbacks.
- `Spark/Workspace.swift`: owns sessions, selection, close confirmation, and preferences.
- `Spark/ContentView.swift`: SwiftUI chrome and the AppKit terminal host.
- `Spark/SparkApp.swift`: native windows, menus, app lifetime, and Sparkle.
- `scripts/release.sh`: signing, notarization, appcast generation, and publication.
- `scripts/generate-icon.swift`: reproducible macOS icon artwork.
