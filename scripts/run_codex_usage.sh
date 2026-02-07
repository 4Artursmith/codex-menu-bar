#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Codex Usage.xcodeproj"
SCHEME="Codex Usage"
DERIVED_DATA="$ROOT_DIR/.derived-data"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Codex Menu Bar.app"

if [[ ! -d "/Applications/Xcode.app" ]]; then
  echo "Xcode not found at /Applications/Xcode.app"
  echo "Install Xcode from App Store, then run this script again."
  exit 1
fi

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

echo "Building $SCHEME..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build finished, but app bundle not found:"
  echo "$APP_PATH"
  exit 1
fi

echo "Launching app..."
open "$APP_PATH"
echo "Done."
