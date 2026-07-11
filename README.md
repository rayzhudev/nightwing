# Nightwing

Nightwing is a local-first music player for macOS and iPhone with first-class Nightcore playback. The default Nightcore preset plays at `sqrt(2)` speed with pitch linked to speed, producing a +6 semitone lift; speed and pitch can also be adjusted independently.

## Features

- Local libraries with albums, playlists, queue management, watched folders, and support for formats including FLAC.
- High-quality Nightcore and pitch-preserving speed controls.
- macOS YouTube Music discovery, album previews, cancellable downloads, and local playback through the normal Nightwing queue.
- Synced lyrics from LRCLIB, plus optional local transcription on macOS using an app-managed `faster-whisper` runtime and model.
- App-managed library and lyric sidecars. Imported audio files are referenced in place and are not modified.
- A shared SwiftUI core with platform-specific macOS and iPhone shells.

## Build

Open `Nightwing.xcodeproj` in Xcode and run either the `Nightwing macOS` or `Nightwing iOS` scheme.

For the normal macOS development loop, double-click `Rebuild Nightwing.command`. It builds a fresh Debug app, replaces the repository-local `Nightwing.app`, and launches it.

## Distribution

`./Rebuild Nightwing.command --release` creates a Developer ID signed and notarized macOS build, validates the bundled downloader helper, and writes the distributable archive to `dist/Nightwing-macOS.zip`.

The release path requires the configured Developer ID certificate and the `nightwing-notary` keychain profile. Generated apps, Derived Data, and `dist/` are intentionally ignored by Git.

See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the original product and technical plan.
