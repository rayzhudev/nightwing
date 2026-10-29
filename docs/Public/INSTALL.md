## Install, prerequisites, backup and recovery

### Install

Requires macOS 26 or later, Apple Silicon or Intel. Unzip Nightwing-macOS.zip, then drag Nightwing.app to Applications and open it normally. Verify the ZIP against the accompanying SHA-256 file before installing. The Developer ID signed/notarized app should pass Gatekeeper; do not bypass a signature or malware warning. No App Store/TestFlight installation is provided.

Core local import/playback works offline. Online discovery depends on Google service availability. Downloads / online playback require user-installed yt-dlp, ffmpeg/ffprobe and a JavaScript runtime supported by yt-dlp (Deno recommended). Install them from their official projects or a trusted package manager, for example an existing Homebrew installation: `brew install yt-dlp ffmpeg deno`. Nightwing searches PATH, /opt/homebrew/bin and /usr/local/bin. Nightwing does not install Homebrew or these tools and does not use a stale helper left by older versions. Their updates and licences are your installation's responsibility.

Optional transcription downloads a model and may provision a private Python engine. You can cancel/retry it. Local audio is not uploaded; see Privacy for network hosts. Settings > Playback shows model status. Playlist OAuth is optional and bring-your-own-developer-client for this beta: see README's service setup. A public Google/Spotify application approval is not claimed.

### Backup and restore

Quit Nightwing before copying data. Back up the entire ~/Library/Application Support/Nightwing directory, the com.rayzhu.nightwing.macos preferences domain, and original music folders separately. The library references original audio paths; copying the JSON alone is not an audio backup. Keychain credentials do not migrate with this directory; reconnect accounts on the new Mac. Restore into a quit app, preserve the old directory, then relaunch. File bookmarks/path changes may require reimporting missing originals.

If LocalLibrary.json is corrupt, Nightwing restores a valid LocalLibrary.json.backup and preserves the unreadable original. If neither can be read, saving is blocked. Quit, preserve both files, restore a known-good backup, reopen and Retry. Do not delete the unreadable library to silence an error unless you deliberately want a fresh library. Missing originals are marked missing; reattach the disk or reimport their new location. Playback errors do not erase your library.

### Uninstall / erase local data

Disconnect each connected service while online, and revoke provider access through Google permissions / Spotify Apps as needed. Quit the app, then move Nightwing.app to Trash. For full local erasure, optionally move ~/Library/Application Support/Nightwing to Trash after backing it up; this includes downloaded audio, lyrics, backup/unreadable copies, models, helpers from older versions and runtime logs. Original imported audio elsewhere is not removed.

Remove the app preferences only if you want to erase settings, recent searches and client IDs (`defaults delete com.rayzhu.nightwing.macos` while the app is quit). Use Keychain Access to remove only entries with service com.rayzhu.nightwing.music-services and com.rayzhu.nightwing.oauth-client-secrets if retained. Do not delete unrelated Keychain items. External Homebrew tools, pre-existing Python environments and ~/.cache/huggingface are shared with other software and must be handled separately. Deleting local data does not delete cloud playlists or provider logs.

### Beta limits

No automatic updater. Replace the app manually for updates, keep a library backup before upgrading, and retain the previous app if you may need to roll back. Online extraction can stop working when providers change. Runtime dependency resolution is version-bounded but not fully locked. Automated checks cannot substitute for interactive sign-in with each user's developer account, or testing every audio device/codec on both CPU architectures.
