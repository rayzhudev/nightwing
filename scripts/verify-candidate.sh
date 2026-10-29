#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
zip_path="${1:-$project_dir/dist/Nightwing-macOS.zip}"
pre_notary=false
provision=false
for option in "${@:2}"; do
  case "$option" in
    --pre-notary) pre_notary=true ;;
    --provision) provision=true ;;
    *) echo "Unknown option: $option" >&2; exit 64 ;;
  esac
done
qa_root="$(mktemp -d /private/tmp/nightwing-candidate-qa.XXXXXX)"
evidence_dir="$project_dir/dist/verification-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$qa_root/extracted" "$qa_root/offline/fixtures" "$qa_root/gui/fixtures" "$evidence_dir"
shasum -a 256 "$zip_path" > "$evidence_dir/zip.sha256"
ditto -x -k "$zip_path" "$qa_root/extracted"
app="$qa_root/extracted/Nightwing.app"
binary="$app/Contents/MacOS/Nightwing macOS"
codesign --verify --deep --strict --verbose=2 "$app" > "$evidence_dir/signature.txt" 2>&1
codesign -dvv "$app" >> "$evidence_dir/signature.txt" 2>&1
lipo "$binary" -verify_arch arm64 x86_64
if "$pre_notary"; then
  xcrun stapler validate "$app" > "$evidence_dir/staple.txt" 2>&1 || true
  spctl --assess --type execute --verbose=4 "$app" > "$evidence_dir/gatekeeper.txt" 2>&1 || true
  printf '%s\n' 'PRE-NOTARY QA ONLY: not distribution-ready; Gatekeeper and stapling are not passed.' > "$evidence_dir/NOT-FOR-DISTRIBUTION.txt"
else
  xcrun stapler validate "$app" > "$evidence_dir/staple.txt" 2>&1
  spctl --assess --type execute --verbose=4 "$app" > "$evidence_dir/gatekeeper.txt" 2>&1
fi
otool -L "$binary" > "$evidence_dir/linked-libraries.txt"
for name in PRIVACY.md THIRD_PARTY_NOTICES.md LICENSE.txt INSTALL.md RELEASE_NOTES.md; do
  cmp "$project_dir/docs/Public/$name" "$app/Contents/Resources/Public/$name"
done
[[ ! -e "$app/Contents/Resources/yt-dlp" ]]
python3 - "$qa_root" <<'PYTHON'
import sys,wave
from pathlib import Path
root=Path(sys.argv[1])
with wave.open(str(root/'source.wav'),'wb') as f:
 f.setnchannels(1);f.setsampwidth(2);f.setframerate(44100);f.writeframes(bytes(44100*2*2))
PYTHON
/usr/bin/afconvert -f flac -d flac "$qa_root/source.wav" "$qa_root/offline/fixtures/test.flac"
/usr/bin/afconvert -f m4af -d aac "$qa_root/source.wav" "$qa_root/offline/fixtures/test.m4a"
/usr/bin/afconvert -f AIFF -d BEI16 "$qa_root/source.wav" "$qa_root/offline/fixtures/test.aiff"
ditto "$qa_root/offline/fixtures" "$qa_root/gui/fixtures"
# Enforce network denial for core local acceptance; never change system networking.
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network-outbound)' /usr/bin/env NIGHTWING_PROFILE_DIRECTORY="$qa_root/offline" "$binary" --release-smoke-test > "$evidence_dir/offline.log" 2>&1
cp "$qa_root/offline/smoke-result.json" "$evidence_dir/offline-smoke.json"
[[ "$(plutil -extract status raw -o - "$evidence_dir/offline-smoke.json")" == "passed" ]]
flags=(--release-smoke-test)
if "$provision"; then flags+=(--provision-lyrics-runtime --download-lyrics-model); fi
if "$pre_notary"; then
  # This locally built signed app is not quarantined; do not suppress Gatekeeper warnings.
  NIGHTWING_PROFILE_DIRECTORY="$qa_root/gui" "$binary" "${flags[@]}" > "$evidence_dir/signed-candidate.log" 2>&1
else
  # Quarantine only this disposable extracted copy, then exercise actual Launch Services.
  xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");NightwingQA;" "$app"
  spctl --assess --type execute --verbose=4 "$app" > "$evidence_dir/quarantined-gatekeeper.txt" 2>&1
  open -n -g -W --env "NIGHTWING_PROFILE_DIRECTORY=$qa_root/gui" "$app" --args "${flags[@]}"
fi
cp "$qa_root/gui/smoke-result.json" "$evidence_dir/signed-candidate-smoke.json"
[[ "$(plutil -extract status raw -o - "$evidence_dir/signed-candidate-smoke.json")" == "passed" ]]
shasum -a 256 -c "$evidence_dir/zip.sha256"
printf '%s\n' "$qa_root" > "$evidence_dir/qa-profile-path.txt"
printf 'Exact candidate QA completed. Check notarization status in evidence: %s\n' "$evidence_dir"
