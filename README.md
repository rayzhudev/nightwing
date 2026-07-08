# Nightwing

Nightwing is a personal local-file music player for iPhone and macOS with first-class Nightcore playback.

The app references audio files in place instead of copying them into its own library. The default Nightcore preset plays at `sqrt(2)` speed with pitch linked to speed, producing a +6 semitone lift. Users can also adjust speed and pitch manually.

See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the full product and technical plan.

## V1 Scope

- Local files only.
- Latest iOS and macOS.
- Shared SwiftUI codebase with platform-specific shells.
- Standard audio formats including FLAC.
- No iCloud sync.
- No playlist import/export.
- Folder watching only for folders the user has already opened.

