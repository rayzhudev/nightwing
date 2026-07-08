# Nightwing Implementation Plan

## Product Scope

Nightwing is a personal local-file music player for iPhone and macOS. Its primary differentiator is first-class Nightcore playback: a one-tap mode that plays music at `sqrt(2)` speed by default while keeping pitch linked to speed, producing a +6 semitone lift.

The app is local-only. It does not integrate with Spotify, Apple Music streaming, cloud libraries, or social services. It references files in place, similar to VLC, rather than copying audio into an app-managed library.

## V1 Targets

- Platforms: latest iOS and latest macOS.
- UI stack: SwiftUI, with a shared codebase and platform-specific shells.
- Audio stack: AVFoundation / AVAudioEngine.
- Storage: local app database/state only, no iCloud sync.
- Distribution: personal-use first, not App Store-first.

## V1 File Support

The app should accept standard audio files that Apple platforms commonly support:

- `.mp3`
- `.m4a`
- `.aac`
- `.alac`
- `.wav`
- `.aif`
- `.aiff`
- `.caf`
- `.flac`

Unsupported files should fail gracefully with a visible status, not crash or silently disappear.

## Library Model

Nightwing stores references to files and folders, not copied audio.

### macOS

- Users can add files or folders.
- Folder entries are remembered.
- Folders that the user has already opened can be watched for changes.
- The app stores persistent access using security-scoped bookmarks when sandboxing requires it.
- If access is lost or a file moves, the UI shows a locate/relink flow.

### iPhone

- Users add files or folders through the Files picker.
- The app stores durable file references where available.
- If access expires, the UI asks the user to reselect the item.

### Metadata

The library database stores:

- File URL/bookmark
- Title
- Artist
- Album
- Album artist
- Genre
- Track number
- Disc number
- Duration
- Artwork cache key
- File type
- Date added
- Last played date
- Play count
- Missing/unavailable state

The app does not write tags back to source files in V1.

## Playback Model

Playback is centralized in a shared `PlayerEngine`.

Core responsibilities:

- Load a track from a file URL.
- Decode through AVFoundation.
- Play, pause, stop, seek, next, previous.
- Maintain current time and duration.
- Publish player state to SwiftUI.
- Maintain a queue.
- Apply speed/pitch settings.
- Update Now Playing metadata on iOS/macOS where practical.

### Nightcore Settings

Default preset:

- Name: Nightcore
- Speed: `sqrt(2)` = `1.41421356237`
- Pitch behavior: linked to speed
- Musical result: +6 semitones

Configurable options:

- Nightcore on/off
- Speed presets: `1.0x`, `1.25x`, `sqrt(2)`, `1.5x`, `2.0x`
- Custom speed slider
- Pitch offset slider in semitones
- Toggle: link pitch to speed
- Toggle: preserve pitch

Internal model:

- `PlaybackProfile`
- `speed`
- `pitchSemitones`
- `isPitchLinkedToSpeed`
- `isPitchPreserved`

## UX Direction

Nightwing should feel clean and native, closer to Apple Music than Spotify. The interface should use Liquid Glass selectively as a functional navigation/control layer, not as decoration.

### Liquid Glass Rules

- Use glass for navigation bars, sidebars, toolbars, floating player controls, and compact overlays.
- Do not put glass on every row or list item.
- Avoid glass-on-glass stacking.
- Keep content readable before visual effect intensity.
- Respect reduced transparency, increased contrast, and reduced motion.
- Use tint only for primary actions and current playback state.

### iPhone Layout

Primary tabs:

- Library
- Search
- Playlists
- Now

Persistent elements:

- Mini-player above tab bar when a track is loaded.
- Full Now Playing sheet/screen with artwork, transport controls, scrubber, queue, and Nightcore controls.

Expected interactions:

- Tap track to play.
- Long press track for Play Next, Add to Queue, Add to Playlist, Show Album, Locate File.
- Pull/search library.
- One-tap Nightcore toggle in Now Playing.

### macOS Layout

Main anatomy:

- Sidebar: Library, Songs, Albums, Artists, Playlists, Folders.
- Main content: dense native lists/tables.
- Bottom persistent player bar.
- Optional right queue/inspector panel.

Expected shortcuts:

- Space: play/pause.
- Left/right: seek or previous/next depending focus.
- Command-F: search.
- Command-N: new playlist.
- Command-O: add files/folder.

## Data Model

Core entities:

- `Track`
- `Album`
- `Artist`
- `Playlist`
- `PlaylistItem`
- `FolderSource`
- `PlaybackQueue`
- `PlaybackProfile`

Implementation can begin with Codable JSON persistence for speed and migrate to SwiftData only if the model starts needing richer querying. Since this is personal-use V1, a simple local store is acceptable if it is durable and easy to debug.

## Project Structure

Preferred shape:

```text
Nightwing.xcodeproj
Shared/
  Models/
  Playback/
  Library/
  Persistence/
  UI/
App-iOS/
  NightwingIOSApp.swift
  iPhoneRootView.swift
App-macOS/
  NightwingMacApp.swift
  MacRootView.swift
docs/
  IMPLEMENTATION_PLAN.md
```

The shared layer should not depend on platform-specific views. Platform-specific shells can depend on shared models, playback, and reusable UI components.

## Build Milestones

### Milestone 1: Project Skeleton

- Create a buildable Xcode project.
- Add iOS and macOS app targets.
- Add shared Swift files.
- Add basic app icons/placeholders if needed.
- Confirm `xcodebuild -list` works.

### Milestone 2: Core Models and Persistence

- Define track, playlist, folder, queue, and playback profile models.
- Add a local JSON store.
- Add sample/in-memory data paths for previews.
- Add file-type helpers.

### Milestone 3: Library Import

- Add file/folder import services.
- Read basic metadata using AVFoundation.
- Persist file references.
- Track missing/unavailable files.
- Add macOS folder watching for user-opened folders.

### Milestone 4: Playback Engine

- Implement AVAudioEngine-backed playback.
- Add queue support.
- Implement speed/pitch profile.
- Add Nightcore preset.
- Publish observable playback state.

### Milestone 5: UI

- Build iPhone tab shell.
- Build macOS sidebar shell.
- Build shared mini-player and Now Playing controls.
- Build library lists, search, playlists, and queue panel.
- Apply native clean styling and restrained Liquid Glass/material usage.

### Milestone 6: Verification

- Build macOS target.
- Build iOS simulator target.
- Test import, playback, Nightcore toggle, custom speed, queue, and missing-file handling.
- Record known limitations.

## Initial Sub-Agent Workstreams

The first implementation pass should split into disjoint write scopes:

1. Project scaffolding and build settings.
2. Shared domain models, persistence, and library import services.
3. Shared playback engine and playback profile logic.
4. SwiftUI shells and player/library UI.

Sub-agents must not revert or overwrite changes from other agents. Each worker should keep to its owned paths and list changed files in its final response.

## V1 Non-Goals

- Streaming services.
- iCloud sync.
- Playlist import/export.
- Tag editing.
- EQ.
- Crossfade.
- Gapless playback.
- Lyrics.
- App Store polish, monetization, onboarding, or analytics.

