#!/bin/bash
# Package the already-built app. Signing and notarization belong to release.sh.
set -euo pipefail
if [[ $# != 2 || ! -d "$1" || ! -f "$1/Contents/Info.plist" ]]; then
  echo 'Usage: scripts/package-dmg.sh path/to/Spark.app path/to/Spark-VERSION.dmg' >&2
  exit 1
fi
app="$1"
dmg="$2"
[[ ! -e "$dmg" ]] || { echo "Refusing to replace existing image: $dmg" >&2; exit 1; }
mkdir -p "$(dirname "$dmg")"
staging=$(mktemp -d "${TMPDIR:-/tmp}/spark-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Spark.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Spark -srcfolder "$staging" -format UDZO "$dmg"
hdiutil verify "$dmg"
