## Nightwing 0.3.0 (3) — direct public beta

Changes since 0.2.0 (commit 1947ebd), based on source commit 695d0ed plus public-beta hardening:

- Optional YouTube/YouTube Music and Spotify playlist connections using read-only OAuth/PKCE and device-only Keychain storage; imports preserve service links and match local songs rather than obtaining service audio.
- More reliable library persistence, validated backups, missing-primary restoration, corrupt-file preservation and blocked unsafe saves.
- Serial, cancellable lyric generation with priority/retry controls; reuse synced/plain lyrics and instrumental metadata before local transcription when lookup is enabled.
- Recursive watched-folder updates, imported-playlist refresh, improved queue/bookmark handling, playback progress and download-error diagnostics.
- New Privacy & Help settings with bundled privacy, component inventory, licence positioning, install/backup/recovery and uninstall instructions. Online lyric lookup defaults OFF for new profiles.
- Isolated test/QA library, preferences and credentials; OAuth callback waiting responds to task cancellation.
- Public-beta download packaging now uses separately installed yt-dlp, ffmpeg and a supported JavaScript runtime. The historical GPLv3+ PyInstaller helper is deliberately not redistributed; there is no bundled helper version to confuse with the source or an installed copy. Optional local transcription remains available on demand.

This is a macOS 26+ universal direct-download beta, not an App Store release. Connected services require your own provider developer clients and may be subject to provider development-mode restrictions. No publication is performed by building this candidate.
