import Foundation

/// Represents a single track found via online search (YouTube, etc.)
public struct OnlineSearchResult: Identifiable, Equatable, Sendable {
    public let id: String          // YouTube video ID as unique identifier
    public let title: String
    public let artist: String?     // nil when not extractable
    public let duration: TimeInterval?
    public let sourceURL: URL      // original video URL (YouTube or other)
    public let thumbnailURL: URL?  // video thumbnail URL
    public let provider: OnlineSearchProvider
    
    /// State of this result in the download pipeline
    public enum DownloadState: Equatable, Sendable {
        case idle
        case downloading(progress: Double)   // 0.0..1.0
        case completed(fileURL: URL)         // downloaded file path
        case failed(String)                  // error message
        
        public static func == (lhs: OnlineSearchResult.DownloadState, rhs: OnlineSearchResult.DownloadState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case let (.downloading(l), .downloading(r)): return l == r
            case let (.completed(l), .completed(r)): return l.path == r.path
            case let (.failed(l), .failed(r)): return l == r
            default: return false
            }
        }
    }
    
    public var downloadState: DownloadState = .idle
    
    public init(
        id: String,
        title: String,
        artist: String? = nil,
        duration: TimeInterval? = nil,
        sourceURL: URL,
        thumbnailURL: URL? = nil,
        provider: OnlineSearchProvider = .youtube
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
        self.sourceURL = sourceURL
        self.thumbnailURL = thumbnailURL
        self.provider = provider
    }
}

/// Represents an album or playlist found via online search.
public struct OnlineAlbumSearchResult: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String?
    public let detailText: String?
    public let sourceURL: URL
    public let thumbnailURL: URL?
    public let provider: OnlineSearchProvider
    public var downloadState: OnlineSearchResult.DownloadState = .idle

    public init(
        id: String,
        title: String,
        artist: String? = nil,
        detailText: String? = nil,
        sourceURL: URL,
        thumbnailURL: URL? = nil,
        provider: OnlineSearchProvider = .youtube
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.detailText = detailText
        self.sourceURL = sourceURL
        self.thumbnailURL = thumbnailURL
        self.provider = provider
    }
}

/// Which online search provider is used
public enum OnlineSearchProvider: String, Codable, Sendable {
    case youtube
    case soundcloud
    
    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .soundcloud: return "SoundCloud"
        }
    }
}

extension OnlineSearchResult.DownloadState: Identifiable {
    public var id: String {
        switch self {
        case .idle: return "idle-\(UUID())"
        case let .downloading(p): return "dl-\(p)"
        case let .completed(u): return "done-\(u.path)"
        case let .failed(e): return "fail-\(e)"
        }
    }
}
