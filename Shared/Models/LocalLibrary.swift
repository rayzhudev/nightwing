import Foundation

public struct PlaybackResumeState: Codable, Equatable, Sendable {
    public var currentTime: TimeInterval
    public var wasPlaying: Bool
    public var repeatMode: PlaybackRepeatMode
    public var profile: PlaybackProfile
    public var updatedAt: Date

    public init(
        currentTime: TimeInterval = 0,
        wasPlaying: Bool = false,
        repeatMode: PlaybackRepeatMode = .none,
        profile: PlaybackProfile = .nightcore,
        updatedAt: Date = Date()
    ) {
        self.currentTime = currentTime
        self.wasPlaying = wasPlaying
        self.repeatMode = repeatMode
        self.profile = profile
        self.updatedAt = updatedAt
    }
}

public struct LocalLibrary: Codable, Equatable, Sendable {
    public var tracks: [Track]
    public var playlists: [Playlist]
    public var folderSources: [FolderSource]
    public var queue: PlaybackQueue
    public var playbackResumeState: PlaybackResumeState?
    public var playbackProfiles: [PlaybackProfile]
    public var selectedPlaybackProfileName: String?
    public var schemaVersion: Int

    public init(
        tracks: [Track] = [],
        playlists: [Playlist] = [],
        folderSources: [FolderSource] = [],
        queue: PlaybackQueue = PlaybackQueue(),
        playbackResumeState: PlaybackResumeState? = nil,
        playbackProfiles: [PlaybackProfile] = [.normal, .nightcore],
        selectedPlaybackProfileName: String? = nil,
        schemaVersion: Int = 1
    ) {
        self.tracks = tracks
        self.playlists = playlists
        self.folderSources = folderSources
        self.queue = queue
        self.playbackResumeState = playbackResumeState
        self.playbackProfiles = playbackProfiles
        self.selectedPlaybackProfileName = selectedPlaybackProfileName
        self.schemaVersion = schemaVersion
    }

    public static let empty = LocalLibrary()

    public mutating func upsertTrack(_ track: Track) {
        if let index = tracks.firstIndex(where: { $0.id == track.id || $0.fileURL == track.fileURL }) {
            var updatedTrack = track
            updatedTrack.id = tracks[index].id
            updatedTrack.dateAdded = tracks[index].dateAdded
            updatedTrack.lastPlayedDate = tracks[index].lastPlayedDate
            updatedTrack.playCount = tracks[index].playCount
            if updatedTrack.playbackNormalizationGain == nil {
                updatedTrack.playbackNormalizationGain = tracks[index].playbackNormalizationGain
            }
            if updatedTrack.playbackEndTime == nil {
                updatedTrack.playbackEndTime = tracks[index].playbackEndTime
            }
            if updatedTrack.playbackAnalysisVersion == nil {
                updatedTrack.playbackAnalysisVersion = tracks[index].playbackAnalysisVersion
            }
            tracks[index] = updatedTrack
        } else {
            tracks.append(track)
        }
    }

    public mutating func upsertTracks(_ newTracks: [Track]) {
        for track in newTracks {
            upsertTrack(track)
        }
    }

    public mutating func deleteTrack(id trackID: Track.ID) {
        tracks.removeAll { $0.id == trackID }
        for index in playlists.indices {
            playlists[index].items.removeAll { $0.trackID == trackID }
            playlists[index].dateModified = Date()
        }
    }

    public mutating func upsertFolderSource(_ folderSource: FolderSource) {
        if let index = folderSources.firstIndex(where: { $0.id == folderSource.id || $0.folderURL == folderSource.folderURL }) {
            folderSources[index] = folderSource
        } else {
            folderSources.append(folderSource)
        }
    }

    @discardableResult
    public mutating func createPlaylist(named name: String) -> Playlist {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmedName.isEmpty ? "New Playlist" : trimmedName)
        playlists.append(playlist)
        return playlist
    }

    public mutating func renamePlaylist(id: Playlist.ID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        playlists[index].name = trimmedName
        playlists[index].dateModified = Date()
    }

    public mutating func deletePlaylist(id: Playlist.ID) {
        playlists.removeAll { $0.id == id }
    }

    public mutating func addTrack(_ trackID: Track.ID, toPlaylist playlistID: Playlist.ID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].items.append(PlaylistItem(trackID: trackID))
        playlists[index].dateModified = Date()
    }

    public mutating func removePlaylistItem(id itemID: PlaylistItem.ID, fromPlaylist playlistID: Playlist.ID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].items.removeAll { $0.id == itemID }
        playlists[index].dateModified = Date()
    }

    @discardableResult
    public mutating func movePlaylistItem(id itemID: PlaylistItem.ID, inPlaylist playlistID: Playlist.ID, to destinationIndex: Int) -> Bool {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let sourceIndex = playlists[playlistIndex].items.firstIndex(where: { $0.id == itemID }),
              !playlists[playlistIndex].items.isEmpty else { return false }

        let clampedDestination = min(max(destinationIndex, playlists[playlistIndex].items.startIndex), playlists[playlistIndex].items.count - 1)
        guard sourceIndex != clampedDestination else { return false }

        let item = playlists[playlistIndex].items.remove(at: sourceIndex)
        playlists[playlistIndex].items.insert(item, at: clampedDestination)
        playlists[playlistIndex].dateModified = Date()
        return true
    }

    public mutating func markMissingTracks(fileManager: FileManager = .default) {
        for index in tracks.indices {
            guard tracks[index].fileURL.isFileURL else {
                tracks[index].availability = .available
                continue
            }
            tracks[index].availability = fileManager.fileExists(atPath: tracks[index].fileURL.path) ? .available : .missing
        }
    }

}
