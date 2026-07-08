import Foundation

public actor JSONLocalLibraryStore {
    public enum StoreError: Error, Sendable {
        case unableToCreateApplicationSupportDirectory
    }

    public let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
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
    ) throws -> JSONLocalLibraryStore {
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.unableToCreateApplicationSupportDirectory
        }

        let directoryURL = applicationSupportURL.appendingPathComponent(applicationName, isDirectory: true)
        let libraryURL = directoryURL.appendingPathComponent("LocalLibrary.json")
        return JSONLocalLibraryStore(fileURL: libraryURL, fileManager: fileManager)
    }

    public func load() throws -> LocalLibrary {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(LocalLibrary.self, from: data)
    }

    public func save(_ library: LocalLibrary) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let data = try encoder.encode(library)
        let temporaryURL = directoryURL.appendingPathComponent(".\(fileURL.lastPathComponent).tmp")
        try data.write(to: temporaryURL, options: [.atomic])

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: fileURL)
    }

    public func update(_ transform: (inout LocalLibrary) throws -> Void) throws -> LocalLibrary {
        var library = try load()
        try transform(&library)
        try save(library)
        return library
    }
}
