import Foundation

public struct Album: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var albumArtist: String?
    public var trackIDs: [Track.ID]
    public var artworkCacheKey: String?

    public init(
        id: UUID = UUID(),
        title: String,
        albumArtist: String? = nil,
        trackIDs: [Track.ID] = [],
        artworkCacheKey: String? = nil
    ) {
        self.id = id
        self.title = title
        self.albumArtist = albumArtist
        self.trackIDs = trackIDs
        self.artworkCacheKey = artworkCacheKey
    }
}
