#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA_DIR="/private/tmp/nightwing-derived-data-macos"
BUILT_APP_PATH="$DERIVED_DATA_DIR/Build/Products/Debug/Nightwing macOS.app"
PUBLISHED_APP_PATH="$PROJECT_DIR/Nightwing.app"

cd "$PROJECT_DIR"

echo "Building Nightwing for macOS..."
echo

if xcodebuild \
  -project Nightwing.xcodeproj \
  -scheme "Nightwing macOS" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build; then
	  echo
	  echo "Build succeeded."
	  echo "Creating double-clickable app..."

	  osascript -e 'tell application id "com.rayzhu.nightwing.macos" to quit' >/dev/null 2>&1 || true
	  sleep 1
	  rm -rf "$PUBLISHED_APP_PATH"
	  ditto "$BUILT_APP_PATH" "$PUBLISHED_APP_PATH"

	  echo "Restarting Nightwing..."
	  open "$PUBLISHED_APP_PATH"

	  echo
	  echo "Nightwing is running from the latest build."
	  echo "You can also open it later by double-clicking:"
	  echo "$PUBLISHED_APP_PATH"
else
  echo
  echo "Build failed. Review the output above."
fi

echo
read -k 1 "?Press any key to close this window."
