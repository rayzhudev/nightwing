import Foundation

public enum LyricsGenerationStatus: String, Codable, Equatable, Sendable {
    case none
    case ready
    case failed
}

public struct LyricsMetadata: Codable, Equatable, Hashable, Sendable {
    public var cacheKey: String
    public var status: LyricsGenerationStatus
    public var generatedAt: Date?
    public var modelName: String?
    public var errorDescription: String?

    public init(
        cacheKey: String,
        status: LyricsGenerationStatus = .none,
        generatedAt: Date? = nil,
        modelName: String? = nil,
        errorDescription: String? = nil
    ) {
        self.cacheKey = cacheKey
        self.status = status
        self.generatedAt = generatedAt
        self.modelName = modelName
        self.errorDescription = errorDescription
    }
}

public struct LyricsLine: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct LyricsDocument: Codable, Equatable, Sendable {
    public var trackID: Track.ID
    public var trackTitle: String
    public var artist: String?
    public var album: String?
    public var sourceFilePath: String
    public var sourceFileSize: Int64?
    public var sourceModifiedAt: Date?
    public var modelName: String
    public var transcriptionSpeed: Double
    public var generatedAt: Date
    public var languageCode: String?
    public var lines: [LyricsLine]

    public init(
        trackID: Track.ID,
        trackTitle: String,
        artist: String? = nil,
        album: String? = nil,
        sourceFilePath: String,
        sourceFileSize: Int64? = nil,
        sourceModifiedAt: Date? = nil,
        modelName: String,
        transcriptionSpeed: Double,
        generatedAt: Date = Date(),
        languageCode: String? = nil,
        lines: [LyricsLine]
    ) {
        self.trackID = trackID
        self.trackTitle = trackTitle
        self.artist = artist
        self.album = album
        self.sourceFilePath = sourceFilePath
        self.sourceFileSize = sourceFileSize
        self.sourceModifiedAt = sourceModifiedAt
        self.modelName = modelName
        self.transcriptionSpeed = transcriptionSpeed
        self.generatedAt = generatedAt
        self.languageCode = languageCode
        self.lines = lines
    }

    public func activeLineIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        if let index = lines.firstIndex(where: { time >= $0.startTime && time < $0.endTime }) {
            return index
        }

        return lines.lastIndex(where: { $0.startTime <= time })
    }
}
