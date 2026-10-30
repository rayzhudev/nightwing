**Developer Preview 0.3.1 (4): signed, universal and unnotarized, with bundled media tools.** The existing 0.3.0 GitHub preview remains available unchanged.

## What's new in 0.3.1 (4)

[Download the Mac Developer Preview](https://github.com/rayzhudev/nightwing/releases/tag/v0.3.1-dev-preview.1) · [Install guide](INSTALL.md)

Changes since 0.2.0:

- **Connected playlists:** optional YouTube/YouTube Music and Spotify connections with read-only OAuth/PKCE and device-only Keychain storage. Imports preserve service links and match local songs; they do not obtain service audio.
- **Safer library saves:** validated backups, recovery for missing/corrupt library files and preservation of unreadable data.
- **Better lyrics workflow:** serial, cancellable generation with priority/retry controls; reuse of synced/plain lyrics and instrumental metadata when lookup is enabled.
- **Library and playback improvements:** recursive watched-folder updates, imported-playlist refresh, queue/bookmark handling, playback progress and download diagnostics.
- **Privacy & Help settings:** privacy, attribution, licensing, installation and recovery guides. Online lyric lookup defaults off for new profiles.
- **System accent colour:** macOS controls, highlights and selection now use the live system accent by default; saved custom colours are preserved. This is not a change to the app’s dark background theme.
- **Optional online tools:** downloads use bundled universal yt-dlp, CPython, FFmpeg/ffprobe, Node and EJS; no Homebrew setup is required. Tool updates come only with a replacement app. Exact inventory, notices and required corresponding source accompany the app. On-device transcription remains available on demand.

### Before installing

Requires **macOS 26+**; includes Apple Silicon and Intel slices. This **Developer Preview is signed but not notarized**: follow the [first-launch Open Anyway instructions](INSTALL.md#install). No iPhone binary, automatic updater or production-support commitment is provided. Playlist connections need your own Google/Spotify developer clients.

Back up application data and original music before upgrading. Native Apple Silicon/Rosetta playback, recovery checks, 41 isolated tests and optional runtime/model provisioning passed in prior audit evidence; physical Intel, real provider sign-in/revocation, all audio devices and the quarantined Finder first launch remain unverified. Optional dependencies are not fully locked; online functionality depends on upstream services.

For exact build identity and verification boundaries, see the [preview manifest](https://github.com/rayzhudev/nightwing/blob/main/docs/DEVELOPER_PREVIEW.md). Read [privacy](PRIVACY.md), [component notices](THIRD_PARTY_NOTICES.md) and [licence positioning](LICENSE.txt) for the corresponding details. [Report a non-sensitive issue](https://github.com/rayzhudev/nightwing/issues) with reproduction steps, app/macOS version and architecture; redact private data.
