import Foundation

public struct FolderSource: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var folderURL: URL
    public var bookmarkData: Data?
    public var name: String
    public var isRecursive: Bool
    public var dateAdded: Date
    public var lastScannedDate: Date?
    public var availability: LibraryAvailability

    public init(
        id: UUID = UUID(),
        folderURL: URL,
        bookmarkData: Data? = nil,
        name: String? = nil,
        isRecursive: Bool = true,
        dateAdded: Date = Date(),
        lastScannedDate: Date? = nil,
        availability: LibraryAvailability = .available
    ) {
        self.id = id
        self.folderURL = folderURL
        self.bookmarkData = bookmarkData
        self.name = name ?? folderURL.lastPathComponent
        self.isRecursive = isRecursive
        self.dateAdded = dateAdded
        self.lastScannedDate = lastScannedDate
        self.availability = availability
    }
}
