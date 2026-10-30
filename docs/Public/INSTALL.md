## Install

Requires **macOS 26.0 or later**, on Apple Silicon or Intel. Local music playback needs no account or additional software.

> **Developer Preview:** Nightwing 0.3.0 (3) is Developer ID signed by Ray Zhu (team `6G8K3FNTVJ`) but **not notarized**, so macOS requires a first-launch exception. Use the per-app **Open Anyway** flow below. On macOS versions that offer it, Finder **right-click > Open** may present the confirmation directly; if it does not, use System Settings. A signature is not Apple notarization.

1. **Download** the [preview ZIP and its matching `.sha256`](https://github.com/rayzhudev/nightwing/releases/tag/v0.3.0-dev-preview.1). In Terminal, switch to the download directory and verify:

   ```sh
   shasum -a 256 -c Nightwing-0.3.0-b3-DEVELOPER-PREVIEW-UNNOTARIZED.zip.sha256
   ```

   Check that the result is `OK`. The checksum checks file integrity; the release page and package `CANDIDATE.json` identify the build.
2. **Install.** Unzip the download and drag **Nightwing.app** to **Applications**. If replacing an earlier version, quit it, [back up your data](#backup-and-restore) and keep the previous app for rollback.
3. **Open once** from Finder. Dismiss the macOS verification dialog with **Done** or **OK**.
4. **Allow the first launch.** Open **System Settings > Privacy & Security**, scroll to **Security**, find the Nightwing blocked message and click **Open Anyway**. Authenticate if asked, then click **Open**. The option is normally available for about an hour after the blocked attempt. Later launches normally work from Applications or Spotlight.

If device-management policy prevents this exception, contact your administrator. If the warning instead says the app **will damage your computer**, is **damaged**, or has an invalid/modified signature, stop and [report the exact warning](https://github.com/rayzhudev/nightwing/issues). Do not disable Gatekeeper or remove quarantine in Terminal.

## First run

- Choose **Add Files** or **Add Folder** to import local audio, then select a song to play.
- Try **Nightcore** in the playback controls, or adjust speed and pitch independently.
- Keep original audio files available: imports reference them in place and do not modify them. Library metadata and lyrics are stored separately by Nightwing.

## Optional features

### Online discovery, downloads and playback

Discovery depends on Google service availability. Downloads and online playback require separately installed **yt-dlp**, **ffmpeg/ffprobe** and a [JavaScript runtime supported by yt-dlp](https://github.com/yt-dlp/yt-dlp/wiki/EJS) (Deno recommended). With Homebrew already installed:

```sh
brew install yt-dlp ffmpeg deno
```

Nightwing searches `PATH`, `/opt/homebrew/bin` and `/usr/local/bin`. It does not install Homebrew or these tools, or use an old bundled helper. Updates and licences for these tools are managed by your installation. Only download content you are entitled to use and comply with provider terms.

### Lyrics and transcription

Online synced lyric lookup is off for new profiles; enable it in **Settings > Playback** if wanted. Optional local transcription may download a model and provision a private Python engine. Model status appears in **Settings > Playback**; generation can be cancelled or retried. Transcription does not upload audio, but setup downloads use the network. See [privacy and network access](PRIVACY.md).

### Connected playlists

Connections are optional and require your own provider developer clients in this preview. Follow the [YouTube and Spotify setup guide](https://github.com/rayzhudev/nightwing/blob/main/docs/Public/CONNECTIONS.md). Importing a playlist brings metadata and local-library matches, not service audio.

## Backup and restore

Quit Nightwing before copying data. Back up the entire `~/Library/Application Support/Nightwing` directory, the `com.rayzhu.nightwing.macos` preferences domain, and original music folders separately. Copying library JSON alone is not an audio backup. Keychain credentials do not migrate with this directory; reconnect accounts on a new Mac.

Restore while the app is quit, preserve the old directory, then relaunch. Moved files or changed bookmarks may require reimporting missing originals.

If `LocalLibrary.json` is missing or corrupt, Nightwing restores a valid `LocalLibrary.json.backup`, preserving an unreadable original. If neither can be read, saving is blocked. Quit, preserve both files, restore a known-good backup, reopen and Retry. Do not delete the unreadable library merely to silence an error. Missing originals can be restored by reattaching their disk or reimporting their new location; playback errors do not erase the library.

## Update or uninstall

There is no automatic updater. For updates, quit Nightwing and replace the app manually, keeping a library backup and the previous app if you need to roll back. Rebuilding a repository-local app does not update the installed copy.

To uninstall, disconnect connected services while online, revoke access through Google permissions or Spotify Apps as needed, quit Nightwing and move **Nightwing.app** to Trash. To erase local data too:

- After backing it up, optionally move `~/Library/Application Support/Nightwing` to Trash. This includes downloaded audio, lyrics, backup/unreadable copies, models, old helpers and runtime logs. Original imported audio elsewhere is not removed.
- To erase settings, recent searches and client IDs, run `defaults delete com.rayzhu.nightwing.macos` while the app is quit.
- In Keychain Access, remove only retained entries for `com.rayzhu.nightwing.music-services` and `com.rayzhu.nightwing.oauth-client-secrets`, not unrelated items.

External tools, pre-existing Python environments and `~/.cache/huggingface` may be shared with other software; manage these separately. Local deletion does not delete cloud playlists, provider logs or backups elsewhere.

## Preview limits and support

Native Apple Silicon and Rosetta were tested, not physical Intel hardware or every audio device/codec. Real provider sign-in/revocation and the quarantined Finder/Open Anyway interaction remain manual acceptance items; the instructions above are not a claim of completed interactive testing. Optional dependencies are version-bounded, not fully locked, and provider changes can interrupt online extraction. See [verification details](https://github.com/rayzhudev/nightwing/blob/main/docs/RELEASE_READINESS.md).

[Report non-sensitive bugs](https://github.com/rayzhudev/nightwing/issues), checking existing issues first. Include **0.3.0 (3)**, the ZIP filename/checksum, macOS version, CPU architecture, steps, expected/actual behavior and exact error. Support is best-effort. Do not post tokens, client secrets, full library databases, personal paths, private playlists or audio. No private support intake is configured.
