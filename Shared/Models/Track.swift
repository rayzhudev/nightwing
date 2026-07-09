import Foundation

public struct Track: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var fileURL: URL
    public var bookmarkData: Data?
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var releaseYear: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval?
    public var artworkCacheKey: String?
    public var artworkURL: URL?
    public var artworkBookmarkData: Data?
    public var fileType: AudioFileType
    public var playbackNormalizationGain: Double?
    public var playbackEndTime: TimeInterval?
    public var playbackAnalysisVersion: Int?
    public var lyricsMetadata: LyricsMetadata?
    public var dateAdded: Date
    public var lastPlayedDate: Date?
    public var playCount: Int
    public var availability: LibraryAvailability

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        bookmarkData: Data? = nil,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        genre: String? = nil,
        releaseYear: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval? = nil,
        artworkCacheKey: String? = nil,
        artworkURL: URL? = nil,
        artworkBookmarkData: Data? = nil,
        fileType: AudioFileType,
        playbackNormalizationGain: Double? = nil,
        playbackEndTime: TimeInterval? = nil,
        playbackAnalysisVersion: Int? = nil,
        lyricsMetadata: LyricsMetadata? = nil,
        dateAdded: Date = Date(),
        lastPlayedDate: Date? = nil,
        playCount: Int = 0,
        availability: LibraryAvailability = .available
    ) {
        self.id = id
        self.fileURL = fileURL
        self.bookmarkData = bookmarkData
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.releaseYear = releaseYear
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.artworkCacheKey = artworkCacheKey
        self.artworkURL = artworkURL
        self.artworkBookmarkData = artworkBookmarkData
        self.fileType = fileType
        self.playbackNormalizationGain = playbackNormalizationGain
        self.playbackEndTime = playbackEndTime
        self.playbackAnalysisVersion = playbackAnalysisVersion
        self.lyricsMetadata = lyricsMetadata
        self.dateAdded = dateAdded
        self.lastPlayedDate = lastPlayedDate
        self.playCount = playCount
        self.availability = availability
    }

    public var displayArtist: String {
        artist?.isEmpty == false ? artist! : "Unknown Artist"
    }

    public var displayAlbum: String {
        album?.isEmpty == false ? album! : "Unknown Album"
    }
}
