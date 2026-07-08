import Foundation

public struct Artist: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var trackIDs: [Track.ID]
    public var albumIDs: [Album.ID]

    public init(
        id: UUID = UUID(),
        name: String,
        trackIDs: [Track.ID] = [],
        albumIDs: [Album.ID] = []
    ) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.albumIDs = albumIDs
    }
}
