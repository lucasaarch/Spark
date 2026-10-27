#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift-format format --in-place --recursive Spark SparkTests SparkUITests scripts
scripts/lint.sh --fix
