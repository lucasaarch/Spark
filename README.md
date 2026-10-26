# Spark

A little more possible. A native macOS terminal with graphite surfaces, warm amber accents, a quiet tab bar, and room to think.

Built with **SwiftUI + AppKit**, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), and [Sparkle](https://sparkle-project.org). macOS 14 or later. Release builds support Apple Silicon and Intel.

## What works

- Metal rendering with a Core Graphics fallback when a GPU surface is unavailable.
- Real PTY sessions running your account's login shell and shell configuration.
- Persistent tabs and independent windows. Switching tabs keeps the process and scrollback alive.
- Window size and position restored between launches.
- Codex and Claude Code awareness: per-tab activity colors, attention indicators, and a live context/usage panel.
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

## Codex and Claude Code

Run either CLI normally. On versions that emit **OSC 7501 (Program Status Protocol)**, Spark automatically shows the provider logo and status color in that terminal's tab, including background tabs:

| Color | State |
| --- | --- |
| Blue | Working |
| Amber | Needs approval, an answer, sign-in, or other attention |
| Green | Done |
| Rose | Error |
| Lavender | Ready |

Tabs keep a fixed height and a single title line. Codex uses the OpenAI logo; Claude Code uses the Anthropic logo. Status is conveyed by color, with the agent name and status also available in the tooltip and accessibility label. Click the agent badge above the terminal to see its reported status, message, and task progress when supplied. Child reports that need attention take priority. Clearing the report or ending the PTY removes the agent UI.

The OpenAI and Anthropic logo assets are from [Simple Icons 13.21.0](https://github.com/simple-icons/simple-icons/tree/13.21.0), distributed under [CC0](https://github.com/simple-icons/simple-icons/blob/13.21.0/LICENSE.md). The marks belong to their respective owners.

The panel displays **live model, context usage, input/output tokens, and plan limits**, plus Claude's estimated session cost. The button above the terminal shows **`x% usage left`**, meaning the remaining account allowance (the lowest remaining percentage among reported 5-hour and weekly limits). Context usage is shown separately in the panel; the tooltip identifies the limiting allowance and activity state. Missing fields say “Not reported”; a missing metric is never presented as zero. Codex tabs start as **Codex** and adopt the conversation name once one is reported.

**Connecting metrics:** open a **new zsh tab** in Spark, then run `codex` or `claude` normally. Spark forwards your normal `.zshenv`, `.zprofile`, `.zshrc`, and `.zlogin`, restores your `ZDOTDIR`, and adds session-local launchers to `PATH`. This also covers `command codex`, `caveman codex`, and aliases such as `cdx='caveman codex'`: child processes find the launcher just as the shell does. User aliases, startup files, and global CLI settings are never edited. The launchers preserve arguments, environment, and exit status; redirected/non-interactive input or output bypasses the integration. Existing tabs, other shells, absolute executable paths, and commands that replace `PATH` may show “Metrics not connected.”

**Data sources and meanings:**

- **Codex:** the wrapper configures the supported `tui.terminal_title` items for that invocation. Spark receives model/context/token/limit updates through OSC title events from that exact PTY. Fixed slots separated by the `app-name` item preserve absent values; truncated slots are discarded. Input/output are session totals rounded by Codex, and limit text retains the client's remaining/used semantics. Only the conversation name appears in the tab. Custom title settings supplied on the command line can override the integration. Validated with Codex 0.164.0.
- **Claude Code:** a per-invocation `--settings` value connects `statusLine` to Spark's helper. This replaces a custom status line **inside Spark only**, displaying a compact model/context/cost footer. Explicit settings passed afterwards can override it. The helper accepts bounded JSON, retains only display metadata and usage figures, and writes atomically into a private temporary folder. Each invocation has its own UUID, and each tab has its own folder. Input/output refer to the **current context from the latest response**, not lifetime session totals. Cost is the client's list-price estimate, not an invoice. Plan limits and context may be absent until a response is received. Validated with Claude Code 2.1.311. The panel polls these local snapshots once per second; the folder is removed when the terminal session is released.

OSC 7501 remains the activity source; metrics never approve tool calls or send prompts. Spark does not scan transcripts, read API keys, poll billing endpoints, or associate sessions by project directory. All displayed values are program-supplied hints, not authenticated process identities. Older clients may lack the required status/title fields. After an abrupt unwrapped client crash, a full terminal reset (`reset`) clears retained activity reports.

References: [Codex title fields](https://github.com/openai/codex/blob/main/codex-rs/tui/src/bottom_pane/title_setup.rs), [Codex status rendering](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget/status_surfaces.rs), [Claude status-line JSON](https://code.claude.com/docs/en/statusline), [Codex activity emitter](https://github.com/openai/codex/blob/main/codex-rs/tui/src/terminal_program_status.rs).

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
- `Spark/AgentActivity.swift` and `Spark/AgentView.swift`: per-PTY agent reports, tab status presentation, and the metrics panel.
- `Spark/AgentMetrics.swift` and `Spark/AgentShellIntegration.swift`: usage snapshots and isolated client integrations for zsh sessions.
- `Spark/SparkApp.swift`: native windows, menus, app lifetime, and Sparkle.
- `scripts/release.sh`: signing, notarization, appcast generation, and publication.
- `scripts/generate-icon.swift`: reproducible macOS icon artwork.
