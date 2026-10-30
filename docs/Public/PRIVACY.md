## Privacy, network access and retention

Applies to Nightwing macOS 0.3.0 Developer Preview, 29 October 2026.

Nightwing is a local-first player. It has no Nightwing account, advertising SDK, telemetry SDK, or developer-operated upload server in this build. Local playback and imports do not require a network connection. macOS and third-party services may collect their own diagnostics; this statement does not set their retention policies.

### What leaves your Mac

- **Online search and artwork:** searches go to YouTube Music / YouTube (Google), including fallback searches. Google receives the query, IP address, request headers and normal connection metadata. Displaying remote artwork contacts its host, commonly i.ytimg.com or service/CDN artwork URLs. Opening source links uses your browser and its existing sign-in state.
- **Downloads / online playback:** when requested, the bundled yt-dlp contacts the selected source and media/CDN hosts. The bundled FFmpeg processes local files; bundled Node executes the bundled EJS solver. Tools are sealed in the app, do not self-update, and ignore external downloader configuration/plugins. Downloader caches and media remain in Nightwing’s application-support directory. No provider cookies or credentials are imported implicitly. Use only content you are entitled to download and comply with the source's terms; discovery is not permission to copy music.
- **Lyrics:** Settings > Playback > automatic synced lyrics lookup controls requests to LRCLIB (lrclib.net). It is OFF for new profiles. If enabled, the song title, artist, album and rounded duration are sent, including during lyrics generation. Audio is not uploaded to LRCLIB. Disable it for local-only lyrics work; existing saved settings are preserved when upgrading.
- **Optional transcription:** downloading the model contacts Hugging Face (huggingface.co and its download/CDN hosts). First generation may download uv from GitHub, managed Python from Astral's Python distribution releases on GitHub, and Python packages from PyPI / files.pythonhosted.org. These hosts receive IP/connection metadata and requested package/model identifiers. This can use hundreds of MB. Transcription then runs on your Mac; Nightwing's local runner does not upload your audio. Model/runtime downloads remain network operations even if lyrics lookup is disabled.
- **Connected playlists:** explicitly connecting opens Google or Spotify authorisation in your browser and starts a temporary HTTP callback listener bound only to 127.0.0.1. Nightwing uses PKCE and read-only playlist/account scopes. The service receives authorisation, token and playlist requests and returns account/playlist metadata. Passwords are entered only on the provider page, not into Nightwing. Developer client IDs are saved in preferences; the Google client secret and OAuth tokens are stored in device-only Keychain items while the Mac is unlocked.

### What stays on your Mac

Library metadata, file paths/bookmarks, play history/counts, queue, imported playlist metadata/source links, downloaded media/artwork, lyrics sidecars, and model/runtime files are kept under ~/Library/Application Support/Nightwing. Original imports are referenced in place and not rewritten. Preferences (including recent searches and client IDs) are kept in the app's macOS preferences domain. Temporary transcription scripts/results and runtime-install logs can be created locally; partial downloads can remain after interrupted operations. A pre-existing Hugging Face cache or compatible locally installed Python environment may be reused.

There is no automatic retention deadline. Data persists until you remove it or uninstall it explicitly. Removing an app alone does not remove its data, Keychain entries, external tools, or external caches. Library recovery may keep LocalLibrary.json.backup and unreadable-* copies; include these in your deletion/backup choices. Recent searches can be cleared in Settings > General.

### Disconnect, revoke and delete

Disconnect in Connected Services first. This invalidates pending Nightwing requests and deletes the local token. Google revocation is attempted online; if offline or unsuccessful, revoke Nightwing's access in your Google account permissions too. Spotify has no public token-revocation endpoint: revoke access in Spotify's Apps account page. Disconnect does not remove imported local playlists, downloaded files, developer credentials, or copies already backed up. See the bundled Install & recovery guide for exact backup/uninstall steps.

Provider policies and retention are controlled by Google/YouTube, Spotify, LRCLIB, GitHub, Astral, PyPI and Hugging Face. Consult their current policies before enabling their features. Nightwing cannot delete their server logs or your browser history. No claim is made that remote services retain nothing.
