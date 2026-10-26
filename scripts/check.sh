#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Spark.xcodeproj -scheme Spark \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackagePluginValidation -disableAutomaticPackageResolution \
  test -only-testing:SparkTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO
