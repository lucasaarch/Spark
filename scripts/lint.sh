#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=0.65.1
checksum=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
if command -v swiftlint >/dev/null && [[ "$(swiftlint version)" == "$version" ]]; then
  lint_binary=$(command -v swiftlint)
else
  tool_dir="$PWD/.build/tools/swiftlint-$version"
  lint_binary="$tool_dir/swiftlint"
  if [[ ! -x "$lint_binary" ]]; then
    mkdir -p .build/tools
    download_dir=$(mktemp -d "$PWD/.build/tools/download.XXXXXX")
    trap 'rm -rf "$download_dir"' EXIT
    curl --fail --location --retry 3 \
      "https://github.com/realm/SwiftLint/releases/download/$version/portable_swiftlint.zip" \
      -o "$download_dir/swiftlint.zip"
    printf '%s  %s\n' "$checksum" "$download_dir/swiftlint.zip" | shasum -a 256 --check
    mkdir "$download_dir/tool"
    ditto -x -k "$download_dir/swiftlint.zip" "$download_dir/tool"
    chmod +x "$download_dir/tool/swiftlint"
    mv "$download_dir/tool" "$tool_dir"
  fi
fi
[[ "$("$lint_binary" version)" == "$version" ]]
if [[ "${1:-}" == --fix ]]; then
  "$lint_binary" lint --config .swiftlint.yml --fix
fi
"$lint_binary" lint --config .swiftlint.yml --strict
