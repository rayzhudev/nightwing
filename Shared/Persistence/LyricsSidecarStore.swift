import Foundation

public actor LyricsSidecarStore {
    public enum StoreError: Error, LocalizedError, Sendable {
        case unableToCreateApplicationSupportDirectory

        public var errorDescription: String? {
            switch self {
            case .unableToCreateApplicationSupportDirectory:
                return "Could not create the lyrics storage folder."
            }
        }
    }

    public let directoryURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func defaultStore(
        applicationName: String = "Nightwing",
        fileManager: FileManager = .default
    ) throws -> LyricsSidecarStore {
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.unableToCreateApplicationSupportDirectory
        }

        let directoryURL = applicationSupportURL
            .appendingPathComponent(applicationName, isDirectory: true)
            .appendingPathComponent("Lyrics", isDirectory: true)
        return LyricsSidecarStore(directoryURL: directoryURL, fileManager: fileManager)
    }

    public func fileURL(for cacheKey: String) -> URL {
        directoryURL.appendingPathComponent(cacheKey).appendingPathExtension("json")
    }

    public func load(cacheKey: String) throws -> LyricsDocument? {
        let url = fileURL(for: cacheKey)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(LyricsDocument.self, from: data)
    }

    public func save(_ document: LyricsDocument, cacheKey: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = fileURL(for: cacheKey)
        let temporaryURL = directoryURL.appendingPathComponent(".\(url.lastPathComponent).tmp")
        let data = try encoder.encode(document)
        try data.write(to: temporaryURL, options: [.atomic])

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temporaryURL, to: url)
    }

    public func delete(cacheKey: String) throws {
        let url = fileURL(for: cacheKey)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
