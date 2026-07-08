import Foundation

public struct PlaybackQueueItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String?
    public var normalizationGain: Double?
    public var playbackEndTime: TimeInterval?
    public var playbackAnalysisVersion: Int?

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        normalizationGain: Double? = nil,
        playbackEndTime: TimeInterval? = nil,
        playbackAnalysisVersion: Int? = nil
    ) {
        self.id = id
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

    private enum CodingKeys: String, CodingKey {
        case items
        case currentIndex
        case isShuffled
        case shuffledOrder
        case shuffledPosition
    }

    public init(
        items: [PlaybackQueueItem] = [],
        currentIndex: Int? = nil,
        isShuffled: Bool = false,
        shuffledOrder: [Int] = [],
        shuffledPosition: Int? = nil
    ) {
        self.items = items
        self.currentIndex = currentIndex.flatMap { items.indices.contains($0) ? $0 : nil }
        self.isShuffled = isShuffled
        self.shuffledOrder = shuffledOrder.filter { items.indices.contains($0) }
        self.shuffledPosition = shuffledPosition.flatMap { self.shuffledOrder.indices.contains($0) ? $0 : nil }

        if isShuffled {
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

        self.init(
            items: items,
            currentIndex: currentIndex,
            isShuffled: isShuffled,
            shuffledOrder: shuffledOrder,
            shuffledPosition: shuffledPosition
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(currentIndex, forKey: .currentIndex)
        try container.encode(isShuffled, forKey: .isShuffled)
        try container.encode(shuffledOrder, forKey: .shuffledOrder)
        try container.encodeIfPresent(shuffledPosition, forKey: .shuffledPosition)
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
        if isShuffled {
            rebuildShuffledOrder()
        } else {
            clearShuffledOrder()
        }
    }

    public mutating func setCurrentItem(id: PlaybackQueueItem.ID) {
        currentIndex = items.firstIndex { $0.id == id }
        if isShuffled {
            syncShuffledPositionToCurrentIndex()
        }
    }

    public mutating func append(_ item: PlaybackQueueItem) {
        items.append(item)
        if currentIndex == nil {
            currentIndex = items.startIndex
        }
    }

    public mutating func append(contentsOf newItems: [PlaybackQueueItem]) {
        guard !newItems.isEmpty else { return }
        let shouldSelectFirst = currentIndex == nil && items.isEmpty
        items.append(contentsOf: newItems)
        if shouldSelectFirst {
            currentIndex = items.startIndex
        }
    }

    public mutating func playNext(_ item: PlaybackQueueItem) {
        guard let currentIndex else {
            append(item)
            return
        }

        items.insert(item, at: min(currentIndex + 1, items.endIndex))
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

        clearShuffledOrder()

        return removed
    }

    public mutating func move(from source: IndexSet, to destination: Int) {
        let movingCurrentID = currentItem?.id
        let offsets = source.filter { items.indices.contains($0) }.sorted()
        guard !offsets.isEmpty else { return }

        let movedItems = offsets.map { items[$0] }
        for offset in offsets.reversed() {
            items.remove(at: offset)
        }

        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let adjustedDestination = min(
            max(destination - removedBeforeDestination, items.startIndex),
            items.endIndex
        )
        items.insert(contentsOf: movedItems, at: adjustedDestination)

        if let movingCurrentID {
            currentIndex = items.firstIndex { $0.id == movingCurrentID }
        }
        clearShuffledOrder()
    }

    public mutating func moveItem(id: PlaybackQueueItem.ID, by offset: Int) {
        guard offset != 0, let sourceIndex = items.firstIndex(where: { $0.id == id }) else { return }

        let destinationIndex = min(max(sourceIndex + offset, items.startIndex), items.count - 1)
        guard sourceIndex != destinationIndex else { return }

        let movingCurrentID = currentItem?.id
        let item = items.remove(at: sourceIndex)
        items.insert(item, at: destinationIndex)
        if let movingCurrentID {
            currentIndex = items.firstIndex { $0.id == movingCurrentID }
        }
        clearShuffledOrder()
    }

    public mutating func moveItem(id: PlaybackQueueItem.ID, to destinationIndex: Int) {
        guard let sourceIndex = items.firstIndex(where: { $0.id == id }) else { return }
        let clampedDestination = min(max(destinationIndex, items.startIndex), items.count - 1)
        guard sourceIndex != clampedDestination else { return }

        let movingCurrentID = currentItem?.id
        let item = items.remove(at: sourceIndex)
        items.insert(item, at: clampedDestination)
        if let movingCurrentID {
            currentIndex = items.firstIndex { $0.id == movingCurrentID }
        }
        clearShuffledOrder()
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
            let current = items[currentIndex]
            let remaining = items.indices
                .filter { $0 != currentIndex }
                .map { items[$0] }
                .shuffled()
            items = [current] + remaining
            self.currentIndex = items.startIndex
        } else {
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
