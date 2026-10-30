# Nightwing

Nightwing is a local-first music player for macOS and iPhone with first-class Nightcore playback. The default Nightcore preset plays at `sqrt(2)` speed with pitch linked to speed, producing a +6 semitone lift; speed and pitch can also be adjusted independently.

> **Developer Preview — GitHub only.** The 0.3.0 (3) candidate is Developer ID signed but **not notarized**. Gatekeeper blocks first open. This is an opt-in evaluation build, not a production-ready release. Read the [exact candidate and distribution notes](docs/DEVELOPER_PREVIEW.md) and [first-open instructions](docs/Public/INSTALL.md) before installing.

## Features

- Local libraries with albums, playlists, queue management, watched folders, and support for formats including FLAC.
- High-quality Nightcore and pitch-preserving speed controls.
- macOS YouTube Music discovery, album previews, cancellable downloads, and local playback through the normal Nightwing queue.
- macOS account connections for YouTube/YouTube Music playlists and Spotify playlists, with secure OAuth token storage, local-library matching, and source links for unmatched items.
- Synced lyrics from LRCLIB, plus optional local transcription on macOS using an app-managed `faster-whisper` runtime and model.
- App-managed library and lyric sidecars. Imported audio files are referenced in place and are not modified.
- A shared SwiftUI core with platform-specific macOS and iPhone shells.

## Open the installed Mac app

Open `/Applications/Nightwing.app`, or search for **Nightwing** in Spotlight. The installed app runs independently of this repository and does not require the rebuild script.

Rebuilding the repository-local app does not update the copy in Applications; replace the installed copy when you want to use a newer build.

## Build

Open `Nightwing.xcodeproj` in Xcode and run either the `Nightwing macOS` or `Nightwing iOS` scheme.

For the normal macOS development loop, double-click `Rebuild Nightwing.command`. It builds a fresh Debug app, replaces the repository-local `Nightwing.app`, and launches it.

Developer Preview 0.3.0 does not bundle yt-dlp. Online downloads/playback require a separately installed yt-dlp, ffmpeg/ffprobe and supported JavaScript runtime (for example `brew install yt-dlp ffmpeg deno` with an existing Homebrew installation). Nightwing automatically enables an installed Deno or Node runtime, including standard Homebrew paths when launched from Finder. Use a runtime supported by [yt-dlp's JavaScript setup guide](https://github.com/yt-dlp/yt-dlp/wiki/EJS); audio extraction also requires ffmpeg. Old prepared helpers are not used by this preview.

## Playlist service setup

Nightwing uses OAuth 2.0 with PKCE and never asks for a Spotify or Google password. In the macOS app, open **Settings > Connections** once to add the developer credentials for each service you want to enable. After setup, use the separate **Connected Services** area in the main sidebar to connect accounts, browse remote playlists, and import them.

- YouTube: create a Google Cloud **Desktop app** OAuth client, enable **YouTube Data API v3**, and configure the OAuth consent screen. Add its client ID and client secret to Nightwing; the secret is stored in the macOS Keychain. Nightwing requests only `youtube.readonly` access.
- Spotify: create a Spotify developer app and register `http://127.0.0.1/callback` as a redirect URI. Spotify Development Mode is restricted to approved users and currently requires the app owner to have Premium.

Remote playlists remain visibly separate from the local Nightwing library. Account import creates a labelled local copy containing playlist metadata, order, and source links—not service audio. Tracks already present in Nightwing are matched automatically and are playable. Other items remain visible with a link to the originating service. YouTube's public API exposes the authenticated user's owned YouTube playlists; it does not expose every YouTube Music-only library collection as a separate API.

OAuth access and refresh tokens are stored in the macOS Keychain as device-only items available while the Mac is unlocked. Google access is revoked when the account is disconnected; Spotify does not provide a public token-revocation endpoint, so Spotify disconnect removes Nightwing's local token and access can also be revoked from the Spotify account page.

## Distribution

The current plan is a **GitHub Releases prerelease only**, with no App Store, TestFlight, automatic updater, or other distribution channel. Nothing has been uploaded or published by this preparation.

The [Developer Preview manifest](docs/DEVELOPER_PREVIEW.md) describes the 0.3.0 (3) signed, unnotarized package. `python3 scripts/package-developer-preview.py` builds the current clean commit, embeds its identity, signs with Developer ID and packages matching bundled/external guides. It does not submit to Apple or publish anything. The generated release body, package identity and checksum identify the exact release assets. No notarization is claimed.

`./Rebuild Nightwing.command --release` is the separate **future notarized-release** pipeline. It attempts Developer ID signing and Apple notarization and produces `dist/Nightwing-macOS.zip` only on success; it is **not** how this preview was prepared. The existing Apple notary profile is blocked by a developer-agreement error. No accepted notarization or stapled ticket is claimed for this preview.

See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the original product and technical plan.

## Reliability and background work

- Library saves keep a validated previous copy in `LocalLibrary.json.backup`. If the main file cannot be decoded, Nightwing preserves it under an `unreadable-…` filename and restores a valid backup. Without a usable backup, saving is blocked and the app shows a recovery notice with Retry.
- Opening Lyrics queues missing lyrics automatically. One song is processed at a time; explicit requests move ahead of background library work. Pending songs can be cancelled in the lyrics panel, and failed songs can be retried.
- When online lyric lookup is enabled, existing synced lyrics or instrumental metadata are used before downloading or running the transcription model. Plain lyrics are reused for alignment. Disabling the setting also disables lookup during local generation.
- macOS watched folders use recursive filesystem notifications with debouncing. A five-minute reconciliation scan remains as a fallback; iPhone uses the periodic fallback.
- Account disconnect invalidates pending requests. Playlist refresh errors keep the account connected and expose a retry action.

## Developer Preview documentation

- [Release notes](docs/Public/RELEASE_NOTES.md)
- [Privacy, network access and retention](docs/Public/PRIVACY.md)
- [Components, provenance and attribution](docs/Public/THIRD_PARTY_NOTICES.md)
- [Licence positioning](docs/Public/LICENSE.txt)
- [Install, prerequisites, backup, recovery and uninstall](docs/Public/INSTALL.md)
- [Release-readiness checklist](docs/RELEASE_READINESS.md)

Current public documents accompany the preview ZIP in Documentation/. The unchanged signed app also contains the earlier audit documents in Settings > Privacy & Help; their notarized-install wording is obsolete for this preview. Online lyric lookup defaults off for new profiles. Supported deployment target: macOS 26+ on Apple Silicon and Intel (universal binary). Native Apple Silicon and Rosetta were tested; physical Intel hardware was not. No iPhone binary, public service OAuth client, or automatic updater is provided.

### Isolated verification

`xcodebuild -project Nightwing.xcodeproj -scheme "Nightwing macOS" -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test`

The shared test scheme sets NIGHTWING_TEST_MODE=1 before the app host starts. Each test host uses a new temporary support directory, a separate preferences suite and no real Keychain credentials. Test network responses use URLProtocol fixtures (OAuth denial uses a local loopback callback).

For the exact packaged app, set `NIGHTWING_PROFILE_DIRECTORY` to a fresh absolute temporary directory and run its Contents/MacOS/Nightwing macOS executable with `--release-smoke-test`. The app checks real imports/playback/recovery and bundled documentation, writes smoke-result.json there and exits. Optional flags `--provision-lyrics-runtime --download-lyrics-model` also exercise real upstream provisioning into the isolated profile. This is a clean-profile acceptance check, not a claim that a separate macOS user or Intel hardware was tested.
