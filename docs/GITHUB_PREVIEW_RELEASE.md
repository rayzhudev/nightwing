## Nightwing 0.3.0 (3) — Developer Preview · macOS · Unnotarized

**GitHub-only prerelease for opt-in developer evaluation. Not a production-ready release.**

The app is **Developer ID signed by Ray Zhu (6G8K3FNTVJ), NOT notarized**, with no stapled ticket. macOS Gatekeeper blocks first open. A signature is not Apple notarization or a malware clearance. No App Store/TestFlight, iPhone binary or automatic updater is provided.

### Download and identity

- `Nightwing-0.3.0-b3-DEVELOPER-PREVIEW-UNNOTARIZED.zip`
- Matching `Nightwing-0.3.0-b3-DEVELOPER-PREVIEW-UNNOTARIZED.zip.sha256`
- SHA-256: `e356a68939e209445abe273206c9083acfbb5a1790117474ffb4fe8e836d34ab`
- App: **0.3.0 (3)**, source `4fbd91edb888c477eecd57f5a3c4fefd5fa3546f`.
- **macOS 26.0+**, universal **Apple Silicon arm64 + Intel x86_64**. Native Apple Silicon and Rosetta tested; physical Intel hardware untested.

Verify in the download directory:

```sh
shasum -a 256 -c Nightwing-0.3.0-b3-DEVELOPER-PREVIEW-UNNOTARIZED.zip.sha256
```

Require `OK`. Read the extracted **READ-FIRST.md** and **Documentation/INSTALL.md** before installation. The sealed app is the unchanged signed candidate; its older in-app install guide incorrectly describes the planned notarized release. The external Developer Preview instructions supersede that wording. This preview has **not** been notarized.

### First open on macOS

1. Back up your existing Nightwing data and original music. Unzip, keep your previous app for rollback, and drag the extracted **Nightwing.app** to **Applications**.
2. Open it once from Finder. Dismiss the “Apple cannot check it for malicious software” / cannot verify it is free of malware dialog with **Done** (or **OK**).
3. Go to **System Settings > Privacy & Security > Security**, find the Nightwing blocked message and click **Open Anyway** (normally available for about an hour after the attempt). Authenticate if asked, then click **Open** in the confirmation. This creates a deliberate per-app exception.
4. If policy prevents the exception, or the warning says the app **will damage your computer**, is **damaged**, or its signature is invalid/modified, stop and report the exact warning. Do not disable Gatekeeper or remove quarantine in Terminal.

The actual quarantined Finder/Open Anyway interaction remains a manual acceptance item; successful isolated executable smoke tests are not that interaction.

### Features and prerequisites

Local libraries, playlists/queue, watched folders, Nightcore/speed/pitch playback, backup recovery, optional lyrics/transcription, and optional YouTube/Spotify playlist metadata connections. Service imports match local songs and preserve source links; they do not obtain service audio.

Core local import/playback works offline. **Online downloads/playback require separately installed yt-dlp, ffmpeg/ffprobe, and a yt-dlp-supported JavaScript runtime** (Deno recommended). With Homebrew already installed: `brew install yt-dlp ffmpeg deno`. These tools are not bundled or installed by Nightwing. OAuth requires your own Google/Spotify developer clients and may have development-mode restrictions. Use only content you are entitled to download and comply with provider terms.

### Privacy, backup and known limits

No Nightwing telemetry/ad SDK or developer-operated upload server. Search/artwork/downloads contact Google and media/CDN hosts; optional lyrics send song metadata to LRCLIB (off for new profiles). Optional local transcription first downloads runtime/packages/models from GitHub/Astral, PyPI and Hugging Face; transcription does not upload your audio. OAuth contacts Google/Spotify and uses a loopback callback; tokens/secrets are stored in device-only Keychain items. Read **Documentation/PRIVACY.md** for network, storage, retention, disconnect and deletion details before enabling online features. Existing preferences survive upgrades.

Quit before backup/restore. Copy the entire `~/Library/Application Support/Nightwing` directory, export/save the `com.rayzhu.nightwing.macos` preferences, and back up original music separately. The JSON is not an audio backup; Keychain items need reconnection. The app restores a validated library backup for a missing/corrupt primary, preserving unreadable data; if neither copy is usable, saving is blocked. Preserve both, restore a known-good backup while quit, reopen and Retry. See **Documentation/INSTALL.md** for rollback, missing originals and uninstall guidance.

Prior audit: 41 isolated tests, native arm64/Rosetta offline playback/codec/recovery checks, and fresh optional runtime/model provisioning/inference passed. Physical Intel hardware, real provider sign-in/revocation and all audio devices remain unverified. Optional dependencies are version-bounded, not fully locked. Online extraction may break with provider changes. No automatic updater, production-support guarantee or project-wide open-source licence is claimed; see **Documentation/LICENSE.txt** and **THIRD_PARTY_NOTICES.md**.

Best-effort non-sensitive bug reports: https://github.com/rayzhudev/nightwing/issues. Include build, ZIP checksum, macOS/architecture, reproduction steps and exact error. Redact credentials, personal paths and playlist data; never attach your full library or audio. No private support intake is configured.
