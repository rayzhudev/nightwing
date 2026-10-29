## Install, prerequisites, backup and recovery

### Install

This is a **GitHub-only Developer Preview**, for opt-in evaluation, not a production release. The app is **Developer ID signed by Ray Zhu (team 6G8K3FNTVJ), but NOT notarized and has no stapled ticket**. It is not unsigned. Gatekeeper rejection as “Unnotarized Developer ID” is expected; a valid signature is not Apple notarization or a malware clearance. No App Store/TestFlight or iPhone package is offered.

Requires **macOS 26.0 or later**, Apple Silicon (arm64) or Intel (x86_64). Both slices are included. Native arm64 and Rosetta x86_64 were tested on Apple Silicon, not physical Intel hardware or every audio device.

1. Download only the named Developer Preview ZIP and its matching `.sha256` from the project's GitHub prerelease. In Terminal, in the download directory, run `shasum -a 256 -c Nightwing-0.3.0-b3-DEVELOPER-PREVIEW-UNNOTARIZED.zip.sha256`. Require `OK`; a checksum detects a mismatch, not publisher authenticity. See the exact identity in READ-FIRST.md / the release notes.
2. Unzip `Nightwing-0.3.0-b3-DEVELOPER-PREVIEW-UNNOTARIZED.zip`. Read **READ-FIRST.md** and these external docs. Drag **Nightwing.app** from the extracted folder to **Applications**. Keep your previous app and back up your library before replacement.
3. In Finder, open **Applications > Nightwing** once. macOS may say Apple cannot check it for malicious software or cannot verify it is free of malware; dismiss that dialog with **Done** (or **OK**, depending on the macOS dialog). Do not move it to Trash if choosing to continue evaluation.
4. Open **System Settings > Privacy & Security**, scroll to **Security**, and find the message that Nightwing was blocked. Click **Open Anyway** (usually available for about one hour after the blocked attempt), authenticate if requested, then click **Open** in the confirmation. This is a deliberate per-app exception for this preview. Subsequent opens normally do not need it.
5. If the exception is unavailable because of device-management policy, or the warning instead says the app **will damage your computer**, is **damaged**, or has an invalid/modified signature, stop and report the exact warning. Do not disable Gatekeeper, remove quarantine with Terminal, or use a system-wide override.

The signed app's bundled INSTALL.md predates this preview and incorrectly says the app should pass Gatekeeper as notarized. **These external preview instructions supersede that wording.** The sealed app has deliberately not been modified or resigned. The real quarantined Finder / Open Anyway flow remains a manual acceptance item; prior isolated executable smoke tests are not that flow.

Core local import/playback works offline. Online discovery depends on Google service availability. Downloads / online playback require user-installed yt-dlp, ffmpeg/ffprobe and a JavaScript runtime supported by yt-dlp (Deno recommended). Install them from their official projects or a trusted package manager, for example an existing Homebrew installation: `brew install yt-dlp ffmpeg deno`. Nightwing searches PATH, /opt/homebrew/bin and /usr/local/bin. Nightwing does not install Homebrew or these tools and does not use a stale helper left by older versions. Their updates and licences are your installation's responsibility.

Optional transcription downloads a model and may provision a private Python engine. You can cancel/retry it. Local audio is not uploaded; see Privacy for network hosts. Settings > Playback shows model status. Playlist OAuth is optional and bring-your-own-developer-client for this preview: see README's service setup. A public Google/Spotify application approval is not claimed.

### Backup and restore

Quit Nightwing before copying data. Back up the entire ~/Library/Application Support/Nightwing directory, the com.rayzhu.nightwing.macos preferences domain, and original music folders separately. The library references original audio paths; copying the JSON alone is not an audio backup. Keychain credentials do not migrate with this directory; reconnect accounts on the new Mac. Restore into a quit app, preserve the old directory, then relaunch. File bookmarks/path changes may require reimporting missing originals.

If LocalLibrary.json is missing, Nightwing restores a valid backup instead of opening a fresh library. If LocalLibrary.json is corrupt, Nightwing restores a valid LocalLibrary.json.backup and preserves the unreadable original. If neither can be read, saving is blocked. Quit, preserve both files, restore a known-good backup, reopen and Retry. Do not delete the unreadable library to silence an error unless you deliberately want a fresh library. Missing originals are marked missing; reattach the disk or reimport their new location. Playback errors do not erase your library.

### Uninstall / erase local data

Disconnect each connected service while online, and revoke provider access through Google permissions / Spotify Apps as needed. Quit the app, then move Nightwing.app to Trash. For full local erasure, optionally move ~/Library/Application Support/Nightwing to Trash after backing it up; this includes downloaded audio, lyrics, backup/unreadable copies, models, helpers from older versions and runtime logs. Original imported audio elsewhere is not removed.

Remove the app preferences only if you want to erase settings, recent searches and client IDs (`defaults delete com.rayzhu.nightwing.macos` while the app is quit). Use Keychain Access to remove only entries with service com.rayzhu.nightwing.music-services and com.rayzhu.nightwing.oauth-client-secrets if retained. Do not delete unrelated Keychain items. External Homebrew tools, pre-existing Python environments and ~/.cache/huggingface are shared with other software and must be handled separately. Deleting local data does not delete cloud playlists or provider logs.

### Preview limits

No automatic updater. Replace the app manually for updates, keep a library backup before upgrading, and retain the previous app if you may need to roll back. Online extraction can stop working when providers change. Runtime dependency resolution is version-bounded but not fully locked. Automated checks cannot substitute for interactive sign-in with each user's developer account, or testing every audio device/codec on both CPU architectures.


### Support and issue reporting

Use https://github.com/rayzhudev/nightwing/issues for non-sensitive preview bugs (check existing issues first). Include version **0.3.0 (3)**, the preview ZIP filename/SHA-256, macOS version, CPU architecture, steps, expected/actual behavior and the exact error. Support is best-effort; there is no production-support or response-time promise. Review/redact diagnostics before posting: do not include tokens, client secrets, full library databases, personal file paths, private playlists or audio. No private support intake is configured; do not post sensitive material publicly.
