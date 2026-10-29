## 0.3.0 (3) Developer Preview readiness

**GO for a GitHub prerelease draft only**, using the exact wrapper/checksum in [DEVELOPER_PREVIEW.md](DEVELOPER_PREVIEW.md) and the proposed [public release body](GITHUB_PREVIEW_RELEASE.md). No release, tag, upload, push, distribution or other public external write has been performed. Publishing requires separate authorisation.

### Verified preparation

- [x] Existing app source commit `4fbd91edb888c477eecd57f5a3c4fefd5fa3546f`, version 0.3.0 (3), original ZIP SHA-256 pinned.
- [x] Valid timestamped Developer ID Application signature (Ray Zhu, team 6G8K3FNTVJ), hardened runtime, macOS 26.0+ arm64/x86_64 slices; no bundled yt-dlp.
- [x] Expected actual state checked: **not notarized, no stapled ticket, Gatekeeper rejected as Unnotarized Developer ID**.
- [x] Preview wrapper includes unchanged signed app plus current external install/first-open, privacy/network/retention, backup/recovery/uninstall, licence, attribution and release documentation.
- [x] Preview disclosures explicitly supersede obsolete notarized-install wording inside the sealed app. No rebuild or resign; exact extracted app bytes/modes and signature verified against the original.
- [x] SHA-256 sidecar uses the preview ZIP basename. Exact preview hash appears in manifest and proposed release body. Generated evidence: `dist/DEVELOPER-PREVIEW-VERIFICATION.json`.
- [x] GitHub-only opt-in prerelease positioning, externally installed online tools, best-effort issue path, no updater/production-readiness claim.

### Completed audit/remediation, not rerun in this documentation/package task

- Historical downloader identified as upstream GPLv3+ combined work; removed from source/distribution instead of inventing a corresponding-source offer. Current optional user-installed yt-dlp/ffmpeg/runtime requirements are disclosed.
- Isolated test preferences/support/model paths and no real Keychain accounts; XCTest hosts do not start app-wide background library work. 41 tests passed (18 XCTest + 23 Swift Testing).
- Exact signed original candidate: native arm64 and Rosetta x86_64 core smoke, outbound-network-denied local acceptance, WAV/AIFF/FLAC/M4A decode, real playback/progress/pause/seek/stop, missing/corrupt audio and library recovery passed.
- Fresh isolated profile: managed Python 3.12.13, faster-whisper 1.2.1, pinned model/hash checks and local inference passed. Evidence remains in ignored `dist/verification-20261029T130210Z/`.
- Earlier private QA incident is recorded in `dist/QA-NOTES.md`; do not claim the earlier audit never touched the real library. This preview preparation does not launch the app or access/change user library data.

### Explicit limits / manual acceptance

- [ ] Actual quarantined Finder launch and System Settings > Privacy & Security > Open Anyway interaction. Documented procedure is not claimed as observed.
- [ ] Physical Intel hardware / all output devices and codecs (Rosetta is not physical Intel).
- [ ] Real Google/Spotify sign-in with bring-your-own developer clients and provider-side revocation confirmation.

These are disclosed preview limitations, not passed production acceptance gates. Runtime transitive dependencies are version-bounded but not fully locked. Online functionality depends on upstream services/tools. No provider approval or project-wide open-source licence is claimed.

### Separate future notarized-release path

Apple notarytool previously returned HTTP 403 because a required developer agreement is missing/expired. No agreement, account, identity or credentials were changed here. `./Rebuild Nightwing.command --release` remains the future clean-commit signed/notarized release builder, not the preview packaging command. After an authorised owner resolves that issue, a new accepted/stapled candidate and exact quarantined Gatekeeper/Launch Services verification are required before claiming a notarized release. The existing `scripts/verify-candidate.sh` compares current bundled docs and is for a newly built candidate; do not use it to reinterpret the unchanged historical preview app as notarized or document-current.

Before any eventual external action, verify the exact local preview checksum, inspect the proposed release body/asset boundary, and keep the GitHub release **draft/prerelease, not latest production** as authorised. Do not upload private QA artifacts or the bare original RC ZIP.
