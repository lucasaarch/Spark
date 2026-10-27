#!/bin/bash
# Run by the tag workflow on an ephemeral macOS runner. Never enable shell tracing here.
set -euo pipefail
cd "$(dirname "$0")/.."
required=(CERTIFICATE_P12_BASE64 CERTIFICATE_PASSWORD APPLE_TEAM_ID APPLE_API_KEY_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER_ID SPARKLE_PRIVATE_KEY GH_TOKEN GITHUB_REPOSITORY GITHUB_REF_NAME RUNNER_TEMP)
missing=0
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Missing secret or environment variable: $name"
    missing=1
  fi
done
[[ "$missing" == 0 ]] || exit 1
[[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo '::error::Use a stable version tag, such as v0.1.0.'; exit 1; }
[[ "${1:-}" != --check ]] || exit 0
version="${GITHUB_REF_NAME#v}"
[[ -f "release-notes/$version.md" ]] || { echo "::error::Missing release-notes/$version.md"; exit 1; }
# Keep the latest feed monotonic, including when someone pushes an older version tag.
latest_metadata="$RUNNER_TEMP/spark-latest.json"
if ! gh api "repos/$GITHUB_REPOSITORY/releases/latest" > "$latest_metadata" 2> "$RUNNER_TEMP/spark-latest-error"; then
  python3 - "$latest_metadata" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if str(result.get('status')) != '404':
    raise SystemExit('Could not verify the latest release; refusing to publish.')
PY
fi
python3 - "$latest_metadata" "$version" <<'PY'
import json, re, sys
latest = json.load(open(sys.argv[1])).get('tag_name')
if latest:
    if not re.fullmatch(r'v\d+\.\d+\.\d+', latest):
        raise SystemExit('Latest release has an unexpected version format.')
    if tuple(map(int, latest[1:].split('.'))) >= tuple(map(int, sys.argv[2].split('.'))):
        raise SystemExit('The release version must be newer than the latest published version.')
PY
signing_dir="$(mktemp -d "$RUNNER_TEMP/spark-signing.XXXXXX")"
keychain="$signing_dir/signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$signing_dir"
}
trap cleanup EXIT
export SPARK_SIGNING_DIR="$signing_dir"
python3 <<'PY'
import os, base64, pathlib
folder = pathlib.Path(os.environ['SPARK_SIGNING_DIR'])
for name, secret in [('certificate.p12', 'CERTIFICATE_P12_BASE64'), ('AuthKey.p8', 'APPLE_API_KEY_BASE64')]:
    path = folder / name
    path.write_bytes(base64.b64decode(os.environ[secret], validate=True))
    path.chmod(0o600)
PY
keychain_password="$(openssl rand -hex 24)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificate.p12" -k "$keychain" -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
mkdir -p .build/release/updates
xcodebuild -project Spark.xcodeproj -scheme Spark -configuration Release \
  -destination 'generic/platform=macOS' -archivePath .build/release/Spark.xcarchive \
  -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackagePluginValidation -disableAutomaticPackageResolution archive \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Developer ID Application' \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$version"
python3 <<'PY'
import os, plistlib
with open('.build/release/ExportOptions.plist', 'wb') as output:
    plistlib.dump({'method': 'developer-id', 'teamID': os.environ['APPLE_TEAM_ID'],
                  'signingStyle': 'manual', 'signingCertificate': 'Developer ID Application'}, output)
PY
xcodebuild -exportArchive -archivePath .build/release/Spark.xcarchive \
  -exportPath .build/release/export -exportOptionsPlist .build/release/ExportOptions.plist
app='.build/release/export/Spark.app'
codesign --verify --deep --strict --verbose=2 "$app"
for arch in arm64 x86_64; do
  lipo "$app/Contents/MacOS/Spark" -verify_arch "$arch"
done
# Notarize, then staple before creating the archive signed by Sparkle.
ditto -c -k --sequesterRsrc --keepParent "$app" .build/release/notarize.zip
notarize() {
  xcrun notarytool submit "$1" \
    --key "$signing_dir/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
    --wait --timeout 20m --output-format json > "$2"
  python3 - "$2" <<'PYTHON'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept this build. See the notarization diagnostics.')
PYTHON
}
notarize .build/release/notarize.zip .build/release/notarization.json
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
# Keep the DMG outside the appcast input directory so Sparkle selects the ZIP.
dmg=".build/release/Spark-$version.dmg"
scripts/package-dmg.sh "$app" "$dmg"
codesign --force --timestamp --sign 'Developer ID Application' --keychain "$keychain" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
notarize "$dmg" .build/release/dmg-notarization.json
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
archive=".build/release/updates/Spark-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
printf '%s' "$SPARKLE_PRIVATE_KEY" | \
  .build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --ed-key-file - --maximum-deltas 0 \
  --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$GITHUB_REF_NAME/" \
  --link "https://github.com/$GITHUB_REPOSITORY" .build/release/updates
python3 - "$GITHUB_REPOSITORY" "$GITHUB_REF_NAME" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse('.build/release/updates/appcast.xml')
enclosure = root.find('./channel/item/enclosure')
assert enclosure is not None and enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature')
assert enclosure.get('url', '').startswith(f'https://github.com/{sys.argv[1]}/releases/download/{sys.argv[2]}/')
PY
shasum -a 256 "$dmg" "$archive" | sed -e 's|.build/release/updates/||' -e 's|.build/release/||' \
  > .build/release/updates/SHA256SUMS
# A draft prevents clients seeing a release before all of its assets are uploaded.
gh release create "$GITHUB_REF_NAME" "$dmg" "$archive" .build/release/updates/appcast.xml \
  .build/release/updates/SHA256SUMS --verify-tag --title "Spark $version" --notes-file "release-notes/$version.md" --draft
gh release edit "$GITHUB_REF_NAME" --draft=false --latest
curl --fail --location --retry 4 --retry-all-errors \
  "https://github.com/$GITHUB_REPOSITORY/releases/latest/download/appcast.xml" \
  -o .build/release/published-appcast.xml
cmp .build/release/updates/appcast.xml .build/release/published-appcast.xml
