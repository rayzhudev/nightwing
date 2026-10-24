import Foundation

public struct Playlist: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [PlaylistItem]
    public var dateCreated: Date
    public var dateModified: Date
    public var importSource: PlaylistImportSource?
    public var importedItems: [ImportedPlaylistItem]?

    public init(
        id: UUID = UUID(),
        name: String,
        items: [PlaylistItem] = [],
        dateCreated: Date = Date(),
        dateModified: Date = Date(),
        importSource: PlaylistImportSource? = nil,
        importedItems: [ImportedPlaylistItem]? = nil
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.importSource = importSource
        self.importedItems = importedItems
    }

    public var displayedItemCount: Int {
        importedItems?.count ?? items.count
    }

    public var unresolvedImportedItems: [ImportedPlaylistItem] {
        importedItems?.filter { $0.matchedTrackID == nil } ?? []
    }
}

public enum MusicPlaylistService: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case youtube
    case spotify

    public var displayName: String {
        switch self {
        case .youtube: "YouTube Music"
        case .spotify: "Spotify"
        }
    }
}

public struct PlaylistImportSource: Codable, Equatable, Hashable, Sendable {
    public var service: MusicPlaylistService
    public var externalID: String
    public var sourceURL: URL?
    public var lastImportedDate: Date

    public init(
        service: MusicPlaylistService,
        externalID: String,
        sourceURL: URL? = nil,
        lastImportedDate: Date = Date()
    ) {
        self.service = service
        self.externalID = externalID
        self.sourceURL = sourceURL
        self.lastImportedDate = lastImportedDate
    }
}

public struct ImportedPlaylistItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?
    public var sourceURL: URL?
    public var artworkURL: URL?
    public var matchedTrackID: Track.ID?

    public init(
        id: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        sourceURL: URL? = nil,
        artworkURL: URL? = nil,
        matchedTrackID: Track.ID? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.sourceURL = sourceURL
        self.artworkURL = artworkURL
        self.matchedTrackID = matchedTrackID
    }
}

public struct PlaylistItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var trackID: Track.ID
    public var dateAdded: Date

    public init(
        id: UUID = UUID(),
        trackID: Track.ID,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.trackID = trackID
        self.dateAdded = dateAdded
    }
}
