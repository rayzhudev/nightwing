## Exact GitHub-only preview candidate

**GitHub-only public prerelease for opt-in developer evaluation, authorised by Ray. Not a production/general-availability release.**

Title: **Nightwing 0.3.0 (3) — Developer Preview · macOS · Unnotarized**
Tag: `v0.3.0-dev-preview.1`. Release body template: [GITHUB_PREVIEW_RELEASE.md](GITHUB_PREVIEW_RELEASE.md).

| Identity | Value |
| --- | --- |
| App version/build | 0.3.0 (3) |
| Embedded source commit | Clean HEAD used by the builder; recorded in package CANDIDATE.json and generated release body |
| Preview package | `dist/Nightwing-0.3.0-b3-DEVELOPER-PREVIEW-UNNOTARIZED.zip` |
| Exact SHA-256 | Adjacent `.zip.sha256`, generated release body and local verification report |
| Local verification report | `dist/DEVELOPER-PREVIEW-VERIFICATION.json` |
| Generated release body | `dist/GITHUB-PREVIEW-RELEASE.md` |
| Signature | Timestamped Developer ID Application: Ray Zhu, team `6G8K3FNTVJ`; hardened runtime |
| Notarization / staple / Gatekeeper | **Not notarized / no ticket / rejected: Unnotarized Developer ID** |
| Deployment target / slices | macOS 26.0+ / arm64 and x86_64 |

### Packaging and verification

`python3 scripts/package-developer-preview.py` requires a clean tree, builds a fresh universal Release archive from HEAD, embeds that commit in Info.plist and applies a timestamped hardened-runtime Developer ID signature. It does not invoke notarization. It verifies version/build/source/minimum OS, signature, universal slices, absent downloader and all five bundled documents against the source commit. It requires expected unnotarized Gatekeeper rejection and absent ticket. It wraps the signed app with READ-FIRST.md, CANDIDATE.json and matching Documentation/, extracts the ZIP, compares every file/symlink and file mode and re-verifies the signature. It writes the checksum, verification report and exact release body, then verifies unchanged HEAD and clean Git state. No app launch, user library access, Apple submission or upload is involved.

ZIP wrapper bytes can vary on regeneration. Publish only the generated ZIP and matching checksum, using `dist/GITHUB-PREVIEW-RELEASE.md` for the exact source/hash. Generated hashes are kept outside tracked source to avoid a self-referential build commit. Do not run the notarized-release builder for this preview.

This release replaces the historical RC with a freshly built/signed app. Both bundled and external guides now accurately disclose the unnotarized Developer Preview; the old RC and its obsolete notarized-install wording are not released.

### Evidence and limits

Prior candidate evidence in `dist/verification-20261029T130210Z/` records 41 isolated tests (18 XCTest + 23 Swift Testing), native arm64 and Rosetta x86_64 offline smoke, WAV/AIFF/FLAC/M4A decode, playback/progress/pause/seek/stop, missing/corrupt audio and library recovery, optional managed runtime/model provisioning and inference. This preparation rechecked packaging and identity; it did not rerun or inflate those functional claims. See `docs/RELEASE_READINESS.md` for acceptance boundaries. Private historical audit/QA files are not release assets.

**Still manual/unverified:** a quarantined Finder launch and the user-facing Open Anyway interaction, physical Intel execution, real provider developer-client OAuth and provider-side revocation, every codec/audio device. No notarization, Apple malware clearance, provider approval, fully locked optional dependencies or broad production readiness is claimed. Optional online tools, privacy/network disclosure, backup/recovery and support are documented in the external public guides.

### Authorised asset boundary

Publish only the preview wrapper ZIP and its matching `.sha256` to the GitHub prerelease. The wrapper contains all five public guides. Do not upload dist wholesale, the original RC ZIP, `.xcarchive`, notary logs/results, private QA notes, isolated profiles or verification logs. Keep the release marked **prerelease**, not latest production release.
