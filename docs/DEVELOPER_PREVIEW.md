## Locally prepared bundled-media candidate

**Nightwing 0.3.1 (4)** is a new signed Developer Preview candidate, not notarized, not published, and not a replacement for the existing 0.3.0 GitHub release. No release asset or repository visibility is changed by the build script.

`python3 scripts/package-developer-preview.py` requires a clean commit, archives universal arm64/x86_64 Swift code, stages universal yt-dlp/CPython, FFmpeg/ffprobe and Node/EJS with exact licences and corresponding source, signs all native code inside-out, then signs the app. It embeds the source commit, compares bundled docs with that commit, verifies nested signatures/architectures and inventory hashes, runs tool version commands natively and under Rosetta, checks the expected unnotarized Gatekeeper rejection and lack of a ticket, creates a wrapper with matching docs and re-verifies extracted bytes, modes and signature.

The new local file is `dist/Nightwing-0.3.1-b4-DEVELOPER-PREVIEW-UNNOTARIZED.zip`, with adjacent checksum and `dist/DEVELOPER-PREVIEW-VERIFICATION.json`. Generated hashes are not written into source before building, avoiding self-referential commits. The generated release-body file is preparation only; publication requires a separate explicit instruction.

No notarization, Apple malware clearance, physical Intel execution or interactive quarantined Finder/Open Anyway test is claimed. Native Apple Silicon/Rosetta media acceptance evidence is recorded separately from package verification. Existing historical transcription acceptance is not represented as freshly rerun. See RELEASE_READINESS.md and DEPENDENCY_PROVENANCE.md.
