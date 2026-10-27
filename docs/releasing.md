# Releasing Spark

The updater reads:

```
https://github.com/lucasaarch/Spark/releases/latest/download/appcast.xml
```

The URL starts working after the first successful release. The GitHub releases page itself is not an appcast. Each release contains `Spark-VERSION.dmg` for installation, `Spark-VERSION.zip` for Sparkle, `appcast.xml`, and `SHA256SUMS` covering both downloads. The DMG contains Spark.app and a shortcut to Applications.

Configure these **repository Actions secrets** at [Settings → Secrets and variables → Actions](https://github.com/lucasaarch/Spark/settings/secrets/actions):

| Secret | Value |
| --- | --- |
| `CERTIFICATE_P12_BASE64` | Base64 of a `.p12` containing your **Developer ID Application** certificate and private key |
| `CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| `APPLE_TEAM_ID` | Apple Developer team identifier |
| `APPLE_API_KEY_BASE64` | Base64 of the App Store Connect API **Team Key** `.p8` used for notarization |
| `APPLE_API_KEY_ID` | That API key's identifier |
| `APPLE_API_ISSUER_ID` | App Store Connect issuer identifier |
| `SPARKLE_PRIVATE_KEY` | Sparkle Ed25519 private key |

`GITHUB_TOKEN` is supplied automatically. The release job maps these secrets to environment variables and checks them before building. Keys are decoded only into a temporary directory and removed on exit. Never commit certificates or private keys. Base64 values may contain line wrapping; whitespace is removed before strict decoding. Encode the entire file, rather than pasting raw PEM content or a file path.

The Sparkle public key is committed in `Config/Spark-Info.plist`. Its matching private key is also stored in the original developer Mac's Keychain under account `lucasaarch.Spark`; preserve it for future releases. Do not generate a different key for each release.

Set the project version and add `release-notes/VERSION.md` before committing. After configuring the Apple secrets and verifying CI on the exact commit (including DMG packaging), publish a new version:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow validates the stable version tag, runs tests, archives a universal app, signs and exports with Developer ID, submits to Apple, checks acceptance, staples and validates the notarization, creates and separately signs/notarizes/staples the DMG, signs the ZIP update archive with Sparkle, and uploads all assets to a draft release before publishing it. Both bundle versions come from the tag. A release must be newer than the latest published version. No unsigned fallback is published if signing or notarization fails.

If publishing fails after creating a draft, inspect and remove that incomplete draft before rerunning the job. Do not replace an already published version; create a new version tag.
