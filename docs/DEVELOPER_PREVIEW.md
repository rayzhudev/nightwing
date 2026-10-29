## Exact GitHub-only preview candidate

**Decision: GO for preparing a GitHub release draft marked prerelease; not for a production/general-availability release.** No release, tag, push, upload or distribution has been performed. Creating even a draft on GitHub requires a separate authorised external action.

Suggested title: **Nightwing 0.3.0 (3) — Developer Preview · macOS · Unnotarized**
Suggested tag: `v0.3.0-dev-preview.1`. Suggested public text: [GITHUB_PREVIEW_RELEASE.md](GITHUB_PREVIEW_RELEASE.md).

| Identity | Value |
| --- | --- |
| App version/build | 0.3.0 (3) |
| Embedded source commit | `4fbd91edb888c477eecd57f5a3c4fefd5fa3546f` |
| Original signed candidate | `dist/Nightwing-0.3.0-b3-UNNOTARIZED-RC.zip` |
| Original candidate SHA-256 | `f84713bc6621c3863e74093a5b2362316cf45b6d721a22df0374c581e027de11` |
| Preview package | `dist/Nightwing-0.3.0-b3-DEVELOPER-PREVIEW-UNNOTARIZED.zip` |
| Preview package SHA-256 | `e356a68939e209445abe273206c9083acfbb5a1790117474ffb4fe8e836d34ab` |
| Matching checksum | `dist/Nightwing-0.3.0-b3-DEVELOPER-PREVIEW-UNNOTARIZED.zip.sha256` |
| Local verification report | `dist/DEVELOPER-PREVIEW-VERIFICATION.json` |
| Signature | Valid timestamped Developer ID Application: Ray Zhu, team `6G8K3FNTVJ`; hardened runtime |
| Notarization / staple / Gatekeeper | **Not notarized / no ticket / rejected: Unnotarized Developer ID** |
| Deployment target / slices | macOS 26.0+ / arm64 and x86_64 |

### Packaging and verification

`python3 scripts/package-developer-preview.py` checks the fixed original ZIP hash, extracts to a disposable directory, validates embedded version/build/source/minimum OS, Developer ID signature/hardened runtime/timestamp, universal slices, absent downloader and all original signed documents against the embedded source commit. It requires the expected unnotarized Gatekeeper rejection and absent ticket. It wraps the unchanged app with READ-FIRST.md, CANDIDATE.json and current Documentation/. It extracts the new ZIP, compares every file/symlink and file mode against the original app and packaging tree, then re-verifies the signature and writes a basename-only checksum plus verification report. No Apple submission, signing, credentials, real library, launch or external write is involved.

ZIP wrapper bytes can vary on regeneration; the script prints the actual hash. If regenerating, update this manifest and the proposed release body to that hash and recheck the adjacent checksum. Do not treat the original ZIP hash as the preview wrapper hash. Do not run the notarized-release builder to prepare this preview.

The original app's sealed documentation remains intact to preserve its exact signature. Its INSTALL.md describes a planned notarized public beta, **which never happened**. The external preview READ-FIRST.md and Documentation/INSTALL.md explicitly supersede that obsolete wording. Keep those disclosures in the wrapper and release body; do not publish the bare original QA ZIP. Updating the in-app wording requires a new separately signed candidate and fresh verification, not silent mutation of this one.

### Evidence and limits

Prior candidate evidence in `dist/verification-20261029T130210Z/` records 41 isolated tests (18 XCTest + 23 Swift Testing), native arm64 and Rosetta x86_64 offline smoke, WAV/AIFF/FLAC/M4A decode, playback/progress/pause/seek/stop, missing/corrupt audio and library recovery, optional managed runtime/model provisioning and inference. This preparation rechecked packaging and identity; it did not rerun or inflate those functional claims. See `docs/RELEASE_READINESS.md` for acceptance boundaries. Private historical audit/QA files are not release assets.

**Still manual/unverified:** a quarantined Finder launch and the user-facing Open Anyway interaction, physical Intel execution, real provider developer-client OAuth and provider-side revocation, every codec/audio device. No notarization, Apple malware clearance, provider approval, fully locked optional dependencies or broad production readiness is claimed. Optional online tools, privacy/network disclosure, backup/recovery and support are documented in the external public guides.

### Proposed asset boundary

Only the preview wrapper ZIP, matching `.sha256`, and optionally the current five `docs/Public/` documents belong on the eventual GitHub prerelease. The wrapper already contains those docs. Do not upload dist wholesale, the original RC ZIP, `.xcarchive`, notary logs/results, private QA notes, isolated profiles or verification logs. Keep the release marked **prerelease**, not latest production release. A draft remains a review step, not permission to publish it.
