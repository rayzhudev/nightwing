**UNPUBLISHED LOCAL CANDIDATE TEMPLATE. Publication/replacement of assets requires separate explicit approval.**

## Nightwing 0.3.1 (4) — Developer Preview

Local-first music playback with Nightcore controls, local libraries, playlists, queues, watched folders and optional lyrics and YouTube/Spotify playlist connections.

> **Mac Developer Preview:** requires **macOS 26+**, Apple Silicon or Intel. Developer ID signed by Ray Zhu, but **not notarized**. First launch requires macOS **Open Anyway**; follow the [short install guide](https://github.com/rayzhudev/nightwing/blob/main/docs/Public/INSTALL.md#install). This is an evaluation build with manual updates, not a production release.

### Download and install

Download these two assets from this prerelease:

- `Nightwing-0.3.1-b4-DEVELOPER-PREVIEW-UNNOTARIZED.zip`
- `Nightwing-0.3.1-b4-DEVELOPER-PREVIEW-UNNOTARIZED.zip.sha256`
<!-- GENERATED_IDENTITY -->
- App: **0.3.1 (4)**. The generated release body and package identity/checksum record the exact source and SHA-256.

Verify in the download directory:

```sh
shasum -a 256 -c Nightwing-0.3.1-b4-DEVELOPER-PREVIEW-UNNOTARIZED.zip.sha256
```

Check for `OK`, unzip and drag **Nightwing.app** to **Applications**, then complete the [first-launch steps](https://github.com/rayzhudev/nightwing/blob/main/docs/Public/INSTALL.md#install). Back up existing Nightwing data and original music before replacing an older app.

### First run and optional features

Use **Add Files** or **Add Folder**, select a song and try **Nightcore**. Local import/playback works offline without an account or extra tools.

Online media tools are bundled: yt-dlp, CPython, FFmpeg/ffprobe and Node/EJS. No Homebrew setup is required. Exact notices, inventory and required source accompany the app. Optional local transcription downloads its runtime/model; it does not upload your audio. Online lyrics lookup starts off for new profiles. [Playlist connections](https://github.com/rayzhudev/nightwing/blob/main/docs/Public/CONNECTIONS.md) require your own provider developer clients and import metadata/local matches, not service audio. Only download content you are entitled to use and follow provider terms.

### Details and support

- [What's new and known limits](https://github.com/rayzhudev/nightwing/blob/main/docs/Public/RELEASE_NOTES.md)
- [Backup, recovery and uninstall](https://github.com/rayzhudev/nightwing/blob/main/docs/Public/INSTALL.md#backup-and-restore)
- [Privacy and network access](https://github.com/rayzhudev/nightwing/blob/main/docs/Public/PRIVACY.md) · [Components and attribution](https://github.com/rayzhudev/nightwing/blob/main/docs/Public/THIRD_PARTY_NOTICES.md) · [Licence positioning](https://github.com/rayzhudev/nightwing/blob/main/docs/Public/LICENSE.txt)
- [Exact preview identity and verification boundaries](https://github.com/rayzhudev/nightwing/blob/main/docs/DEVELOPER_PREVIEW.md)

[Report non-sensitive bugs](https://github.com/rayzhudev/nightwing/issues) with app/macOS version, architecture, ZIP checksum, reproduction steps and exact error. Redact credentials, private paths and playlist data. Support is best-effort; no private support intake is configured. No iPhone binary or project-wide open-source licence is provided.
