import Foundation

public struct Playlist: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [PlaylistItem]
    public var dateCreated: Date
    public var dateModified: Date

    public init(
        id: UUID = UUID(),
        name: String,
        items: [PlaylistItem] = [],
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.dateCreated = dateCreated
        self.dateModified = dateModified
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
