import Foundation

public struct PlaybackQueueItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var trackID: UUID?
    public var url: URL
    public var title: String?
    public var normalizationGain: Double?
    public var playbackEndTime: TimeInterval?
    public var playbackAnalysisVersion: Int?

    public init(
        id: UUID = UUID(),
        trackID: UUID? = nil,
        url: URL,
        title: String? = nil,
        normalizationGain: Double? = nil,
        playbackEndTime: TimeInterval? = nil,
        playbackAnalysisVersion: Int? = nil
    ) {
        self.id = id
        self.trackID = trackID
        self.url = url
        self.title = title
        self.normalizationGain = normalizationGain
        self.playbackEndTime = playbackEndTime
        self.playbackAnalysisVersion = playbackAnalysisVersion
    }
}

public struct PlaybackQueue: Codable, Equatable, Sendable {
    public private(set) var items: [PlaybackQueueItem]
    public private(set) var currentIndex: Int?
    public private(set) var isShuffled: Bool
    private var shuffledOrder: [Int]
    private var shuffledPosition: Int?
    private var unshuffledItems: [PlaybackQueueItem]

    private enum CodingKeys: String, CodingKey {
        case items
        case currentIndex
        case isShuffled
        case shuffledOrder
        case shuffledPosition
        case unshuffledItems
    }

    public init(
        items: [PlaybackQueueItem] = [],
        currentIndex: Int? = nil,
        isShuffled: Bool = false,
        shuffledOrder: [Int] = [],
        shuffledPosition: Int? = nil,
        unshuffledItems: [PlaybackQueueItem] = []
    ) {
        let filteredShuffledOrder = shuffledOrder.filter { items.indices.contains($0) }
        self.items = items
        self.currentIndex = currentIndex.flatMap { items.indices.contains($0) ? $0 : nil }
        self.isShuffled = isShuffled
        self.shuffledOrder = filteredShuffledOrder
        self.shuffledPosition = shuffledPosition.flatMap { filteredShuffledOrder.indices.contains($0) ? $0 : nil }
        self.unshuffledItems = Self.validUnshuffledItems(unshuffledItems, matching: items)

        if isShuffled {
            ensureValidUnshuffledItems()
            ensureValidShuffleOrder()
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decodeIfPresent([PlaybackQueueItem].self, forKey: .items) ?? []
        let currentIndex = try container.decodeIfPresent(Int.self, forKey: .currentIndex)
        let isShuffled = try container.decodeIfPresent(Bool.self, forKey: .isShuffled) ?? false
        let shuffledOrder = try container.decodeIfPresent([Int].self, forKey: .shuffledOrder) ?? []
        let shuffledPosition = try container.decodeIfPresent(Int.self, forKey: .shuffledPosition)
        let unshuffledItems = try container.decodeIfPresent([PlaybackQueueItem].self, forKey: .unshuffledItems) ?? []

        self.init(
            items: items,
            currentIndex: currentIndex,
            isShuffled: isShuffled,
            shuffledOrder: shuffledOrder,
            shuffledPosition: shuffledPosition,
            unshuffledItems: unshuffledItems
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(currentIndex, forKey: .currentIndex)
        try container.encode(isShuffled, forKey: .isShuffled)
        try container.encode(shuffledOrder, forKey: .shuffledOrder)
        try container.encodeIfPresent(shuffledPosition, forKey: .shuffledPosition)
        try container.encode(unshuffledItems, forKey: .unshuffledItems)
    }

    public var isEmpty: Bool {
        items.isEmpty
    }

    public var currentItem: PlaybackQueueItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    public var hasNext: Bool {
        guard let currentIndex else { return false }
        return items.indices.contains(currentIndex + 1)
    }

    public var hasPrevious: Bool {
        guard let currentIndex else { return false }
        return items.indices.contains(currentIndex - 1)
    }

    public mutating func replace(with items: [PlaybackQueueItem], startingAt index: Int = 0) {
        self.items = items
        currentIndex = items.indices.contains(index) ? index : nil
        clearShuffledOrder()
        clearUnshuffledItems()

        if isShuffled {
            shuffleVisibleQueueKeepingCurrent()
        }
    }

    public mutating func setCurrentItem(id: PlaybackQueueItem.ID) {
        currentIndex = items.firstIndex { $0.id == id }
        if isShuffled {
            syncShuffledPositionToCurrentIndex()
        }
    }

    public mutating func append(_ item: PlaybackQueueItem) {
        if isShuffled {
            ensureValidUnshuffledItems()
        }
        items.append(item)
        if isShuffled {
            unshuffledItems.append(item)
        }
        if currentIndex == nil {
            currentIndex = items.startIndex
        }
    }

    public mutating func append(contentsOf newItems: [PlaybackQueueItem]) {
        guard !newItems.isEmpty else { return }
        if isShuffled {
            ensureValidUnshuffledItems()
        }
        let shouldSelectFirst = currentIndex == nil && items.isEmpty
        items.append(contentsOf: newItems)
        if isShuffled {
            unshuffledItems.append(contentsOf: newItems)
        }
        if shouldSelectFirst {
            currentIndex = items.startIndex
        }
    }

    @discardableResult
    public mutating func remapTrackURLs(_ urlsByTrackID: [UUID: URL]) -> Bool {
        guard !urlsByTrackID.isEmpty else { return false }

        var didChange = false

        func remap(_ queueItems: inout [PlaybackQueueItem]) {
            for index in queueItems.indices {
                guard let trackID = queueItems[index].trackID,
                      let updatedURL = urlsByTrackID[trackID],
                      queueItems[index].url != updatedURL else { continue }

                queueItems[index].url = updatedURL
                didChange = true
            }
        }

        remap(&items)
        remap(&unshuffledItems)
        return didChange
    }

    public mutating func playNext(_ item: PlaybackQueueItem) {
        if isShuffled {
            ensureValidUnshuffledItems()
        }
        guard let currentIndex else {
            append(item)
            return
        }

        let insertionIndex = min(currentIndex + 1, items.endIndex)
        items.insert(item, at: insertionIndex)
        if isShuffled {
            let currentItemID = items[currentIndex].id
            let unshuffledInsertionIndex = unshuffledItems.firstIndex { $0.id == currentItemID }
                .map { min($0 + 1, unshuffledItems.endIndex) } ?? unshuffledItems.endIndex
            unshuffledItems.insert(item, at: unshuffledInsertionIndex)
        }
    }

    public mutating func removeUpcoming() {
        guard let currentIndex else {
            items.removeAll()
            clearShuffledOrder()
            return
        }

        let keepThroughIndex = min(currentIndex + 1, items.endIndex)
        items.removeSubrange(keepThroughIndex..<items.endIndex)
        clearShuffledOrder()
        clearUnshuffledItems()
    }

    @discardableResult
    public mutating func remove(id: PlaybackQueueItem.ID) -> PlaybackQueueItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)

        if items.isEmpty {
            currentIndex = nil
        } else if let selected = currentIndex {
            if selected == index {
                currentIndex = min(index, items.count - 1)
            } else if selected > index {
                currentIndex = selected - 1
            }
        }

        if isShuffled {
            unshuffledItems.removeAll { $0.id == id }
        }
        clearShuffledOrder()

        return removed
    }

    @discardableResult
    public mutating func move(from source: IndexSet, to destination: Int) -> Bool {
        let movingCurrentID = currentItem?.id
        let offsets = source.filter { items.indices.contains($0) }.sorted()
        guard !offsets.isEmpty else { return false }

        let movedItems = offsets.map { items[$0] }
        for offset in offsets.reversed() {
            items.remove(at: offset)
        }

        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let adjustedDestination = min(
            max(destination - removedBeforeDestination, items.startIndex),
            items.endIndex
        )
        guard offsets != Array(adjustedDestination..<(adjustedDestination + offsets.count)) else {
            items.insert(contentsOf: movedItems, at: adjustedDestination)
            return false
        }

        items.insert(contentsOf: movedItems, at: adjustedDestination)

        if let movingCurrentID {
            currentIndex = items.firstIndex { $0.id == movingCurrentID }
        }
        clearShuffledOrder()
        clearUnshuffledItems()
        return true
    }

    @discardableResult
    public mutating func moveItem(id: PlaybackQueueItem.ID, by offset: Int) -> Bool {
        guard offset != 0, let sourceIndex = items.firstIndex(where: { $0.id == id }) else { return false }

        let destinationIndex = min(max(sourceIndex + offset, items.startIndex), items.count - 1)
        guard sourceIndex != destinationIndex else { return false }

        let movingCurrentID = currentItem?.id
        let item = items.remove(at: sourceIndex)
        items.insert(item, at: destinationIndex)
        if let movingCurrentID {
            currentIndex = items.firstIndex { $0.id == movingCurrentID }
        }
        clearShuffledOrder()
        clearUnshuffledItems()
        return true
    }

    @discardableResult
    public mutating func moveItem(id: PlaybackQueueItem.ID, to destinationIndex: Int) -> Bool {
        guard let sourceIndex = items.firstIndex(where: { $0.id == id }) else { return false }
        let clampedDestination = min(max(destinationIndex, items.startIndex), items.count - 1)
        guard sourceIndex != clampedDestination else { return false }

        let movingCurrentID = currentItem?.id
        let item = items.remove(at: sourceIndex)
        items.insert(item, at: clampedDestination)
        if let movingCurrentID {
            currentIndex = items.firstIndex { $0.id == movingCurrentID }
        }
        clearShuffledOrder()
        clearUnshuffledItems()
        return true
    }

    @discardableResult
    public mutating func advanceToNext() -> PlaybackQueueItem? {
        guard let currentIndex, items.indices.contains(currentIndex + 1) else { return nil }
        self.currentIndex = currentIndex + 1
        return currentItem
    }

    @discardableResult
    public mutating func advanceToPrevious() -> PlaybackQueueItem? {
        guard let currentIndex, items.indices.contains(currentIndex - 1) else { return nil }
        self.currentIndex = currentIndex - 1
        return currentItem
    }

    @discardableResult
    public mutating func moveToStart() -> PlaybackQueueItem? {
        guard !items.isEmpty else {
            currentIndex = nil
            return nil
        }

        currentIndex = items.startIndex
        return currentItem
    }

    public mutating func setShuffled(_ isShuffled: Bool) {
        guard self.isShuffled != isShuffled else { return }
        self.isShuffled = isShuffled
        if isShuffled {
            shuffleVisibleQueueKeepingCurrent()
        } else {
            restoreUnshuffledOrderKeepingCurrent()
            clearShuffledOrder()
        }
    }

    private mutating func shuffleVisibleQueueKeepingCurrent() {
        guard !items.isEmpty else {
            currentIndex = nil
            clearShuffledOrder()
            return
        }

        if let currentIndex, items.indices.contains(currentIndex) {
            unshuffledItems = items
            let current = items[currentIndex]
            let remaining = items.indices
                .filter { $0 != currentIndex }
                .map { items[$0] }
                .shuffled()
            items = [current] + remaining
            self.currentIndex = items.startIndex
        } else {
            unshuffledItems = items
            items.shuffle()
            currentIndex = items.startIndex
        }
        clearShuffledOrder()
    }

    public mutating func toggleShuffle() {
        setShuffled(!isShuffled)
    }

    private mutating func rebuildShuffledOrder() {
        guard !items.isEmpty else {
            currentIndex = nil
            clearShuffledOrder()
            isShuffled = true
            return
        }

        let currentIndex = currentIndex.flatMap { items.indices.contains($0) ? $0 : nil } ?? items.startIndex
        self.currentIndex = currentIndex
        let remaining = items.indices.filter { $0 != currentIndex }.shuffled()
        shuffledOrder = [currentIndex] + remaining
        shuffledPosition = shuffledOrder.startIndex
    }

    private mutating func ensureValidShuffleOrder() {
        guard !items.isEmpty else {
            currentIndex = nil
            shuffledOrder = []
            shuffledPosition = nil
            return
        }

        let itemIndices = Set(items.indices)
        if Set(shuffledOrder) != itemIndices || shuffledOrder.count != items.count {
            rebuildShuffledOrder()
            return
        }

        if let currentIndex, let position = shuffledOrder.firstIndex(of: currentIndex) {
            shuffledPosition = position
        } else {
            currentIndex = shuffledOrder.first
            shuffledPosition = shuffledOrder.isEmpty ? nil : shuffledOrder.startIndex
        }
    }

    private mutating func syncShuffledPositionToCurrentIndex() {
        guard isShuffled else { return }
        guard let currentIndex else {
            shuffledPosition = nil
            return
        }

        if let position = shuffledOrder.firstIndex(of: currentIndex) {
            shuffledPosition = position
        } else {
            rebuildShuffledOrder()
        }
    }

    private mutating func clearShuffledOrder() {
        shuffledOrder = []
        shuffledPosition = nil
    }

    private mutating func clearUnshuffledItems() {
        unshuffledItems = []
    }

    private mutating func restoreUnshuffledOrderKeepingCurrent() {
        ensureValidUnshuffledItems()
        guard !unshuffledItems.isEmpty else { return }

        let currentItemID = currentItem?.id
        items = unshuffledItems
        currentIndex = currentItemID.flatMap { id in
            items.firstIndex { $0.id == id }
        } ?? currentIndex.flatMap { items.indices.contains($0) ? $0 : nil }
        clearUnshuffledItems()
    }

    private mutating func ensureValidUnshuffledItems() {
        let validItems = Self.validUnshuffledItems(unshuffledItems, matching: items)
        if validItems.count == items.count {
            unshuffledItems = validItems
        } else {
            unshuffledItems = items
        }
    }

    private static func validUnshuffledItems(
        _ candidateItems: [PlaybackQueueItem],
        matching visibleItems: [PlaybackQueueItem]
    ) -> [PlaybackQueueItem] {
        let visibleIDs = visibleItems.map(\.id)
        let visibleIDSet = Set(visibleIDs)
        let candidateIDs = candidateItems.map(\.id)
        guard Set(candidateIDs) == visibleIDSet,
              candidateIDs.count == visibleIDs.count else {
            return []
        }

        return candidateItems
    }

    private mutating func remapShuffledOrderAfterInsert(at insertedIndex: Int) {
        shuffledOrder = shuffledOrder.map { $0 >= insertedIndex ? $0 + 1 : $0 }
        if let shuffledPosition {
            shuffledOrder.insert(insertedIndex, at: min(shuffledPosition + 1, shuffledOrder.endIndex))
        } else {
            shuffledOrder.append(insertedIndex)
        }
        syncShuffledPositionToCurrentIndex()
    }

    private mutating func remapShuffledOrderAfterRemoval(at removedIndex: Int) {
        shuffledOrder = shuffledOrder.compactMap { index in
            if index == removedIndex { return nil }
            return index > removedIndex ? index - 1 : index
        }
        syncShuffledPositionToCurrentIndex()
    }
}
