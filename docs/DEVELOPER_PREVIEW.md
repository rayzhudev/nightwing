## Published bundled-media Developer Preview

**Nightwing 0.3.1 (4)** is the signed, unnotarized [bundled-tools Developer Preview](https://github.com/rayzhudev/nightwing/releases/tag/v0.3.1-dev-preview.1). It does not alter the existing 0.3.0 GitHub release. No Homebrew or user-installed media tools are required.

`python3 scripts/package-developer-preview.py` requires a clean commit, archives universal arm64/x86_64 Swift code, stages universal yt-dlp/CPython, FFmpeg/ffprobe and Node/EJS with exact licences and corresponding source, signs all native code inside-out, then signs the app. It embeds the source commit, compares bundled docs with that commit, verifies nested signatures/architectures and inventory hashes, runs tool version commands natively and under Rosetta, checks the expected unnotarized Gatekeeper rejection and lack of a ticket, creates a wrapper with matching docs and re-verifies extracted bytes, modes and signature.

The release asset is `dist/Nightwing-0.3.1-b4-DEVELOPER-PREVIEW-UNNOTARIZED.zip`, with adjacent checksum and `dist/DEVELOPER-PREVIEW-VERIFICATION.json`. Generated hashes are not written into source before building, avoiding self-referential commits. The generated release body records the exact clean source commit and ZIP hash; the public prerelease publishes that ZIP and its matching checksum. The packaging script itself does not upload.

No notarization, Apple malware clearance, physical Intel execution or interactive quarantined Finder/Open Anyway test is claimed. Native Apple Silicon/Rosetta media acceptance evidence is recorded separately from package verification. Existing historical transcription acceptance is not represented as freshly rerun. See RELEASE_READINESS.md and DEPENDENCY_PROVENANCE.md.
