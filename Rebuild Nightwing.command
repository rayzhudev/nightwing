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
FINAL_ZIP_PATH="$RELEASE_ROOT/Nightwing-macOS.zip"
FINAL_ZIP_CHECKSUM_PATH="$FINAL_ZIP_PATH.sha256"
RELEASE_TEMP_DIR=""
RELEASE_VERIFY_ROOT=""
NOTARY_UPLOAD_ZIP_PATH=""

cd "$PROJECT_DIR"

cleanup_release_temp() {
  if [[ -z "$RELEASE_TEMP_DIR" || ! -d "$RELEASE_TEMP_DIR" ]]; then
    return
  fi

  case "$RELEASE_TEMP_DIR" in
    /private/tmp/nightwing-release.*)
      rm -rf -- "$RELEASE_TEMP_DIR" || echo "Warning: could not remove release temp directory: $RELEASE_TEMP_DIR" >&2
      ;;
    *)
      echo "Warning: refusing to remove unexpected release temp directory: $RELEASE_TEMP_DIR" >&2
      ;;
  esac
}

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
    python3 "$PROJECT_DIR/scripts/build-media-tools.py" --stage "$LOCAL_PUBLISHED_APP_PATH"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_IDENTITY" "$LOCAL_PUBLISHED_APP_PATH"

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

  if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "Release builds require a clean Git working tree."
    echo "Finish, review, and commit the current changes before creating a distributable build."
    return 1
  fi

  if ! security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_IDENTITY" >/dev/null; then
    echo "Missing signing identity:"
    echo "$DEVELOPER_ID_IDENTITY"
    echo
    echo "Install the Developer ID Application certificate with its private key, then run again."
    return 1
  fi

  RELEASE_TEMP_DIR="$(mktemp -d /private/tmp/nightwing-release.XXXXXX)"
  RELEASE_DERIVED_DATA_DIR="$RELEASE_TEMP_DIR/DerivedData"
  RELEASE_VERIFY_ROOT="$RELEASE_TEMP_DIR/final-zip"
  NOTARY_UPLOAD_ZIP_PATH="$RELEASE_TEMP_DIR/Nightwing-notary-upload.zip"
  trap 'cleanup_release_temp' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  mkdir -p "$RELEASE_ROOT"
  rm -rf "$ARCHIVE_PATH" "$RELEASE_APP_PATH" "$FINAL_ZIP_PATH" "$FINAL_ZIP_CHECKSUM_PATH"

  xcodebuild \
    -project Nightwing.xcodeproj \
    -scheme "Nightwing macOS" \
    -configuration Release \
    -derivedDataPath "$RELEASE_DERIVED_DATA_DIR" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    ENABLE_CODE_COVERAGE=NO \
    CLANG_COVERAGE_MAPPING=NO \
    DEAD_CODE_STRIPPING=YES \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    archive

  if [[ ! -d "$ARCHIVED_APP_PATH" ]]; then
    echo "Archive succeeded, but the expected app was not found:"
    echo "$ARCHIVED_APP_PATH"
    return 1
  fi

  ditto "$ARCHIVED_APP_PATH" "$RELEASE_APP_PATH"

  local release_version
  local release_build
  release_version="$(plutil -extract CFBundleShortVersionString raw -o - "$RELEASE_APP_PATH/Contents/Info.plist")"
  release_build="$(plutil -extract CFBundleVersion raw -o - "$RELEASE_APP_PATH/Contents/Info.plist")"
  echo "Archived Nightwing version $release_version ($release_build)."

  local release_binary_path="$RELEASE_APP_PATH/Contents/MacOS/Nightwing macOS"
  if ! lipo "$release_binary_path" -verify_arch arm64 x86_64; then
    echo "Release binary is not universal (arm64 + x86_64):"
    lipo -info "$release_binary_path" || true
    return 1
  fi
  echo "Release binary includes Apple Silicon and Intel architectures."

  python3 "$PROJECT_DIR/scripts/build-media-tools.py" --stage "$RELEASE_APP_PATH"
  local source_commit="$(git rev-parse HEAD)"
  /usr/libexec/PlistBuddy -c "Add :NightwingSourceCommit string $source_commit" "$RELEASE_APP_PATH/Contents/Info.plist"
  for document in PRIVACY.md THIRD_PARTY_NOTICES.md LICENSE.txt INSTALL.md RELEASE_NOTES.md; do
    cmp "$PROJECT_DIR/docs/Public/$document" "$RELEASE_APP_PATH/Contents/Resources/Public/$document"
  done

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
  codesign -dvv "$RELEASE_APP_PATH" 2>&1 | grep -F "runtime"
  echo "Preparing notarization upload..."
  ditto -c -k --keepParent "$RELEASE_APP_PATH" "$NOTARY_UPLOAD_ZIP_PATH"

  echo "Submitting to Apple notary service..."
  if ! xcrun notarytool submit "$NOTARY_UPLOAD_ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$RELEASE_ROOT/notary-result.json" 2> "$RELEASE_ROOT/notary-error.txt"; then
    local blocked_zip="$RELEASE_ROOT/Nightwing-${release_version}-b${release_build}-UNNOTARIZED-RC.zip"
    ditto -c -k --keepParent "$RELEASE_APP_PATH" "$blocked_zip"
    shasum -a 256 "$blocked_zip" > "$blocked_zip.sha256"
    printf '{"sourceCommit":"%s","version":"%s","build":"%s","notarization":"blocked","distributionReady":false}\n' "$source_commit" "$release_version" "$release_build" > "$RELEASE_ROOT/RELEASE-VERIFICATION.json"
    echo "Notarization failed. Signed QA-only candidate preserved (NOT for distribution): $blocked_zip"
    cat "$RELEASE_ROOT/notary-error.txt"
    return 1
  fi
  [[ "$(plutil -extract status raw -o - "$RELEASE_ROOT/notary-result.json")" == "Accepted" ]]

  echo
  echo "Stapling notarization ticket..."
  xcrun stapler staple "$RELEASE_APP_PATH"
  xcrun stapler validate "$RELEASE_APP_PATH"
  spctl --assess --type execute --verbose=4 "$RELEASE_APP_PATH"

  echo
  echo "Creating final distributable zip..."
  ditto -c -k --keepParent "$RELEASE_APP_PATH" "$FINAL_ZIP_PATH"
  rm -f "$NOTARY_UPLOAD_ZIP_PATH"

  echo "Validating the exact distributable zip..."
  mkdir -p "$RELEASE_VERIFY_ROOT"
  ditto -x -k "$FINAL_ZIP_PATH" "$RELEASE_VERIFY_ROOT"

  local verified_app_path="$RELEASE_VERIFY_ROOT/Nightwing.app"
  local verified_binary_path="$verified_app_path/Contents/MacOS/Nightwing macOS"
  if [[ ! -d "$verified_app_path" || ! -e "$verified_app_path/Contents/Resources/MediaTools/INVENTORY.json" ]]; then
    echo "The final zip did not contain the expected bundled-media app."
    return 1
  fi

  if ! lipo "$verified_binary_path" -verify_arch arm64 x86_64; then
    echo "The packaged app is missing a required architecture."
    lipo -info "$verified_binary_path" || true
    return 1
  fi

  [[ "$(plutil -extract NightwingSourceCommit raw -o - "$verified_app_path/Contents/Info.plist")" == "$source_commit" ]]
  for document in PRIVACY.md THIRD_PARTY_NOTICES.md LICENSE.txt INSTALL.md RELEASE_NOTES.md; do
    cmp "$PROJECT_DIR/docs/Public/$document" "$verified_app_path/Contents/Resources/Public/$document"
  done
  codesign --verify --deep --strict --verbose=2 "$verified_app_path"
  xcrun stapler validate "$verified_app_path"
  spctl --assess --type execute --verbose=4 "$verified_app_path"

  local checksum_output
  local final_zip_sha256
  checksum_output="$(shasum -a 256 "$FINAL_ZIP_PATH")"
  final_zip_sha256="${checksum_output%% *}"
  printf '%s  %s\n' "$final_zip_sha256" "${FINAL_ZIP_PATH:t}" > "$FINAL_ZIP_CHECKSUM_PATH"

  printf '{"sourceCommit":"%s","version":"%s","build":"%s","zipSHA256":"%s","bundledDownloader":false,"architectures":["arm64","x86_64"],"signature":"verified","hardenedRuntime":true,"notarization":"Accepted","staple":"validated","gatekeeper":"accepted"}\n' "$source_commit" "$release_version" "$release_build" "$final_zip_sha256" > "$RELEASE_ROOT/RELEASE-VERIFICATION.json"

  echo
  echo "Release package is ready:"
  echo "$FINAL_ZIP_PATH"
  echo "SHA-256: $final_zip_sha256"
  echo "Checksum file:"
  echo "$FINAL_ZIP_CHECKSUM_PATH"
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
