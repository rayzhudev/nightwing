## Nightwing 0.3.0 (3) — GitHub-only Developer Preview (unnotarized)

Changes since 0.2.0 (commit 1947ebd), based on source commit 695d0ed plus preview hardening:

- Optional YouTube/YouTube Music and Spotify playlist connections using read-only OAuth/PKCE and device-only Keychain storage; imports preserve service links and match local songs rather than obtaining service audio.
- More reliable library persistence, validated backups, missing-primary restoration, corrupt-file preservation and blocked unsafe saves.
- Serial, cancellable lyric generation with priority/retry controls; reuse synced/plain lyrics and instrumental metadata before local transcription when lookup is enabled.
- Recursive watched-folder updates, imported-playlist refresh, improved queue/bookmark handling, playback progress and download-error diagnostics.
- New Privacy & Help settings with bundled privacy, component inventory, licence positioning, install/backup/recovery and uninstall instructions. Online lyric lookup defaults OFF for new profiles.
- Isolated test/QA library, preferences and credentials; OAuth callback waiting responds to task cancellation.
- Developer Preview download packaging now uses separately installed yt-dlp, ffmpeg and a supported JavaScript runtime. The historical GPLv3+ PyInstaller helper is deliberately not redistributed; there is no bundled helper version to confuse with the source or an installed copy. Optional local transcription remains available on demand.

This is a GitHub-only prerelease for opt-in developer evaluation, not a production or App Store release. It requires macOS 26+ and contains arm64/x86_64 slices. The unchanged 0.3.0 (3) app from source commit 4fbd91edb888c477eecd57f5a3c4fefd5fa3546f is Developer ID signed (Ray Zhu, team 6G8K3FNTVJ), NOT notarized, has no stapled ticket, and is rejected by Gatekeeper until the user explicitly permits it. See the external INSTALL.md for the exact first-open procedure; the sealed app contains older, superseded notarized-install wording. Connected services require your own provider developer clients and may be subject to provider development-mode restrictions. No publication is performed by building this candidate.


Native Apple Silicon and Rosetta core smoke, offline codec/recovery checks, 41 isolated tests and clean-profile optional runtime/model provisioning passed in prior audit evidence. Physical Intel hardware, real provider sign-in/revocation, all output devices and a quarantined Finder/Open Anyway launch remain unverified. Optional runtime transitive dependencies are not fully locked; online extraction can break when providers change. Back up the full application-support directory and original music before evaluation. No automatic updater or production-readiness claim is made. Report non-sensitive bugs at https://github.com/rayzhudev/nightwing/issues.
