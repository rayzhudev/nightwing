## 0.3.0 (3) Developer Preview readiness

**GO for the user-authorised GitHub-only public prerelease**, using the freshly rebuilt wrapper/checksum and generated release body described in [DEVELOPER_PREVIEW.md](DEVELOPER_PREVIEW.md). This is not production/general-availability approval.

### Release build verification

The preview builder requires a clean committed source tree and records its full commit, version 0.3.0 (3), exact ZIP SHA-256 and verification outcome in ignored `dist/DEVELOPER-PREVIEW-VERIFICATION.json`. It verifies timestamped Developer ID signature (Ray Zhu, team 6G8K3FNTVJ), hardened runtime, macOS 26.0+ arm64/x86_64 slices, no bundled yt-dlp, matching bundled/external guides, expected unnotarized Gatekeeper rejection/no ticket and exact extracted app bytes/modes. These checks run against the new build; historical functional results below are not represented as freshly rerun.

The freshly built app replaces the old RC. Both in-app and external guides now describe the unnotarized preview. Only the final ZIP and checksum are release assets; no updater/production-readiness claim is made.

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

Apple notarytool previously returned HTTP 403 because a required developer agreement is missing/expired. No agreement, account, identity or credentials were changed here. `./Rebuild Nightwing.command --release` remains the future clean-commit signed/notarized release builder, not the preview packaging command. After an authorised owner resolves that issue, a new accepted/stapled candidate and exact quarantined Gatekeeper/Launch Services verification are required before claiming a notarized release. The preview builder intentionally does not run notarytool; no credentials or account agreements are changed.

Before publication, verify the exact local preview checksum and generated release body. Keep the GitHub release **prerelease, not latest production**. Do not upload private QA artifacts or the bare original RC ZIP.
