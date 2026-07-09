#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DERIVED_DATA_DIR="/private/tmp/nightwing-derived-data-macos"
LOCAL_BUILT_APP_PATH="$LOCAL_DERIVED_DATA_DIR/Build/Products/Debug/Nightwing macOS.app"
LOCAL_PUBLISHED_APP_PATH="$PROJECT_DIR/Nightwing.app"

TEAM_ID="6G8K3FNTVJ"
DEVELOPER_ID_IDENTITY="Developer ID Application: Ray Zhu ($TEAM_ID)"
NOTARY_PROFILE="${NIGHTWING_NOTARY_PROFILE:-nightwing-notary}"
RELEASE_ROOT="$PROJECT_DIR/dist"
RELEASE_DERIVED_DATA_DIR="/private/tmp/nightwing-release-derived-data-macos"
ARCHIVE_PATH="$RELEASE_ROOT/Nightwing.xcarchive"
ARCHIVED_APP_PATH="$ARCHIVE_PATH/Products/Applications/Nightwing macOS.app"
RELEASE_APP_PATH="$RELEASE_ROOT/Nightwing.app"
RELEASE_YTDLP_PATH="$RELEASE_APP_PATH/Contents/Resources/yt-dlp"
RELEASE_YTDLP_ENTITLEMENTS_PATH="/private/tmp/nightwing-yt-dlp.entitlements"
NOTARY_UPLOAD_ZIP_PATH="$RELEASE_ROOT/Nightwing-notary-upload.zip"
FINAL_ZIP_PATH="$RELEASE_ROOT/Nightwing-macOS.zip"

cd "$PROJECT_DIR"

build_local() {
  echo "Building Nightwing for macOS..."
  echo

  if xcodebuild \
    -project Nightwing.xcodeproj \
    -scheme "Nightwing macOS" \
    -configuration Debug \
    -derivedDataPath "$LOCAL_DERIVED_DATA_DIR" \
    build; then
    echo
    echo "Build succeeded."
    echo "Creating double-clickable app..."

    osascript -e 'tell application id "com.rayzhu.nightwing.macos" to quit' >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$LOCAL_PUBLISHED_APP_PATH"
    ditto "$LOCAL_BUILT_APP_PATH" "$LOCAL_PUBLISHED_APP_PATH"

    echo "Restarting Nightwing..."
    open "$LOCAL_PUBLISHED_APP_PATH"

    echo
    echo "Nightwing is running from the latest build."
    echo "You can also open it later by double-clicking:"
    echo "$LOCAL_PUBLISHED_APP_PATH"
  else
    echo
    echo "Build failed. Review the output above."
  fi
}

build_release() {
  echo "Building signed Nightwing release for distribution..."
  echo

  if ! security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_IDENTITY" >/dev/null; then
    echo "Missing signing identity:"
    echo "$DEVELOPER_ID_IDENTITY"
    echo
    echo "Install the Developer ID Application certificate with its private key, then run again."
    return 1
  fi

  mkdir -p "$RELEASE_ROOT"
  rm -rf "$ARCHIVE_PATH" "$RELEASE_APP_PATH" "$NOTARY_UPLOAD_ZIP_PATH" "$FINAL_ZIP_PATH"

  xcodebuild \
    -project Nightwing.xcodeproj \
    -scheme "Nightwing macOS" \
    -configuration Release \
    -derivedDataPath "$RELEASE_DERIVED_DATA_DIR" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    archive

  if [[ ! -d "$ARCHIVED_APP_PATH" ]]; then
    echo "Archive succeeded, but the expected app was not found:"
    echo "$ARCHIVED_APP_PATH"
    return 1
  fi

  ditto "$ARCHIVED_APP_PATH" "$RELEASE_APP_PATH"

  echo
  echo "Signing bundled executable resources..."
  if [[ -f "$RELEASE_YTDLP_PATH" ]]; then
    cat > "$RELEASE_YTDLP_ENTITLEMENTS_PATH" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
PLIST

    chmod +x "$RELEASE_YTDLP_PATH"
    codesign \
      --force \
      --options runtime \
      --entitlements "$RELEASE_YTDLP_ENTITLEMENTS_PATH" \
      --timestamp \
      --sign "$DEVELOPER_ID_IDENTITY" \
      "$RELEASE_YTDLP_PATH"
    codesign --verify --strict --verbose=2 "$RELEASE_YTDLP_PATH"
  fi

  echo
  echo "Refreshing Developer ID signature..."
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$DEVELOPER_ID_IDENTITY" \
    "$RELEASE_APP_PATH"

  codesign --verify --deep --strict --verbose=2 "$RELEASE_APP_PATH"

  echo
  echo "Preparing notarization upload..."
  ditto -c -k --keepParent "$RELEASE_APP_PATH" "$NOTARY_UPLOAD_ZIP_PATH"

  echo "Submitting to Apple notary service..."
  xcrun notarytool submit "$NOTARY_UPLOAD_ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo
  echo "Stapling notarization ticket..."
  xcrun stapler staple "$RELEASE_APP_PATH"
  xcrun stapler validate "$RELEASE_APP_PATH"
  spctl --assess --type execute --verbose=4 "$RELEASE_APP_PATH"

  echo
  echo "Creating final distributable zip..."
  ditto -c -k --keepParent "$RELEASE_APP_PATH" "$FINAL_ZIP_PATH"
  rm -f "$NOTARY_UPLOAD_ZIP_PATH"

  echo
  echo "Release package is ready:"
  echo "$FINAL_ZIP_PATH"
}

case "${1:-}" in
  --release)
    build_release
    ;;
  --help|-h)
    echo "Usage:"
    echo "  ./Rebuild Nightwing.command           Build and relaunch local debug app"
    echo "  ./Rebuild Nightwing.command --release Build, sign, notarize, and zip release app"
    ;;
  "")
    build_local
    ;;
  *)
    echo "Unknown option: $1"
    echo "Run with --help for usage."
    exit 64
    ;;
esac

echo
if [[ "${1:-}" == "" && -t 0 ]]; then
  read -k 1 "?Press any key to close this window."
fi
