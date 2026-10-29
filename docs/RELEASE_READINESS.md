## 0.3.0 (3) public-beta readiness

Target: direct Developer ID signed/notarized universal macOS 26+ ZIP. No App Store/TestFlight work and no publication is authorised by this preparation task.

### Source preparation completed

- [x] Validated audit: old 0.2.0 ZIP/version did not match the substantial source delta.
- [x] New 0.3.0 (3) version/build and source-based release notes from 1947ebd to 695d0ed plus beta hardening.
- [x] Public and bundled offline-readable privacy/network/retention, install/backup/recovery/uninstall, licence-positioning and attribution documents; Settings > Privacy & Help.
- [x] Precise historical yt-dlp binary provenance and GPLv3+ combined-work issue identified. Removed from current tree/distributable rather than inventing a legal source offer. Optional user-installed tools are documented; stale prepared copies are not used.
- [x] Tests/QA use isolated library, preferences, model cache and no real Keychain accounts. Shared Xcode test scheme sets isolation before launch.
- [x] 41 tests passed on Apple Silicon (18 XCTest + 23 Swift Testing), including missing-primary restoration, orphaned-backup protection, corrupt-library preservation/backup, missing-file bookmarks, playlist refresh, queue behavior, folder notifications, model integrity, offline lyric/service errors, local-only lyric bypass, OAuth user denial/task cancellation, Google revocation attempt and disconnect/late-result handling.
- [x] Development clean-profile smoke passed: actual WAV import/audio-engine playback/progress/pause/seek/stop, missing/corrupt audio errors and subsequent recovery, persistence/backup recovery, real runtime provisioning, pinned model download/hash verification and local model inference.
- [x] Removed developer-specific OpenClaw Python fallback. New managed Python/cache provisioning remains under the runtime directory. Append-only install logs preserve provenance.
- [x] Release pipeline requires clean Git, embeds final source commit, uses fresh Derived Data, checks universal architectures/docs/signatures/hardened runtime, submits to Apple, staples and reassesses the exact extracted ZIP only after acceptance; failed notarization preserves a clearly labelled QA-only candidate.
- [x] Repeatable exact-candidate verifier includes FLAC/M4A/AIFF decode fixtures, network-denied core smoke, and (after notarization) quarantined Launch Services launch. No system networking or real library is changed.

### External blocker found on 29 October 2026

Apple notarytool using the existing nightwing-notary profile returns HTTP 403: “A required agreement is missing or has expired.” The Developer ID signing identity is available. The account/team owner must sign the required current Apple Developer agreement in the Apple developer account. This task does not accept legal agreements on the owner's behalf.

- [ ] Apple team agreement restored; notarization accepted.
- [ ] Ticket stapled/validated and exact final ZIP accepted by Gatekeeper (including quarantined launch).

Until these pass, this is NOT a distributable public beta. The canonical final ZIP is created only after successful notarization. A `*-UNNOTARIZED-RC.zip` is QA-only, regardless of successful local smoke checks. Post-commit signature/hash/codec/offline/provisioning results are stored beside the candidate in ignored dist/ verification evidence, not inferred from this checklist.

### Explicit beta caveats, not claimed as tested

Real Google/Spotify sign-in with the user's own developer clients, provider-side revocation confirmation, every codec/output device, and execution on physical Intel hardware remain manual acceptance items. Automated OAuth tests use dummy tokens and local/mock responses, never Ray's accounts. Clean-profile isolation is not a separate macOS user account. No provider application approval, automatic updater, fully locked runtime dependency graph, or project-wide open-source licence is claimed. Online features require connectivity and provider/tool compatibility; local playback works offline.

### Finish and publication boundary

After the Apple agreement is resolved, from the clean final commit run `./Rebuild Nightwing.command --release`, then `./scripts/verify-candidate.sh dist/Nightwing-macOS.zip --provision`. Inspect dist/RELEASE-VERIFICATION.json, notary-result.json, checksum and verification evidence; require all acceptance states to pass. Do not reuse the older 0.2.0 ZIP.

Ray would then need to explicitly authorise: **publish the verified 0.3.0 (3) notarized ZIP, its matching SHA-256 file and public release/privacy/prerequisite documents to the chosen public release destination** (for example a GitHub prerelease). No upload/public release is performed by these scripts. A general preparation request does not authorise that publication.
