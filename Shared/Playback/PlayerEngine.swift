import AVFoundation
import Combine
import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif

@MainActor
public final class PlayerEngine: ObservableObject {
    @Published public private(set) var state: PlaybackState {
        didSet {
#if canImport(MediaPlayer)
            nowPlayingController?.updateIfNeeded(from: oldValue, to: state)
#endif
        }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let normalizationGain = AVAudioUnitEQ(numberOfBands: 0)
    private let varispeed = AVAudioUnitVarispeed()
    private let timePitch = AVAudioUnitTimePitch()
    private static let outputHeadroom: Float = 0.92
    private static let maximumPreloadedItems = 40

    private var audioFile: AVAudioFile?
    private var loadedFramePosition: AVAudioFramePosition = 0
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var playbackEndFrame: AVAudioFramePosition = 0
    private var activeScheduleID = 0
    private var activeScheduleItemID: PlaybackQueueItem.ID?
    private var progressTimer: Timer?
    private var playbackAnalysisTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var preloadGeneration = 0
    private var preloadLookaheadCount = 1
    private var preparedItems: [PlaybackQueueItem.ID: PreparedPlaybackItem] = [:]
    private var preparedItemOrder: [PlaybackQueueItem.ID] = []
#if canImport(MediaPlayer)
    private var nowPlayingController: SystemNowPlayingController?
#endif

    public init(profile: PlaybackProfile = .normal) {
        state = PlaybackState(profile: profile)
        configureAudioSession()
        configureEngine()
        apply(profile)
#if canImport(MediaPlayer)
        nowPlayingController = SystemNowPlayingController(player: self)
        nowPlayingController?.activate()
        nowPlayingController?.update(with: state)
#endif
    }

    deinit {
        progressTimer?.invalidate()
        playbackAnalysisTask?.cancel()
        preloadTask?.cancel()
        playerNode.stop()
        engine.stop()
    }

    public func replaceQueue(
        with items: [PlaybackQueueItem],
        startingAt index: Int = 0,
        autoplay: Bool = false,
        preloadLookaheadCount: Int = 1
    ) throws {
        var queue = state.queue
        queue.replace(with: items, startingAt: index)
        self.preloadLookaheadCount = Self.clampedPreloadLookaheadCount(preloadLookaheadCount)
        clearPreloadCache()
        state.queue = queue

        guard let item = queue.currentItem else {
            unload()
            return
        }

        try load(item, autoplay: autoplay)
    }

    public func load(
        url: URL,
        title: String? = nil,
        normalizationGain: Double? = nil,
        playbackEndTime: TimeInterval? = nil,
        playbackAnalysisVersion: Int? = nil,
        autoplay: Bool = false
    ) throws {
        let item = PlaybackQueueItem(
            url: url,
            title: title,
            normalizationGain: normalizationGain,
            playbackEndTime: playbackEndTime,
            playbackAnalysisVersion: playbackAnalysisVersion
        )
        try replaceQueue(with: [item], autoplay: autoplay)
    }

    public func enqueue(
        url: URL,
        title: String? = nil,
        normalizationGain: Double? = nil,
        playbackEndTime: TimeInterval? = nil,
        playbackAnalysisVersion: Int? = nil
    ) {
        var queue = state.queue
        queue.append(
            PlaybackQueueItem(
                url: url,
                title: title,
                normalizationGain: normalizationGain,
                playbackEndTime: playbackEndTime,
                playbackAnalysisVersion: playbackAnalysisVersion
            )
        )
        state.queue = queue
        preloadNextItemIfNeeded()
    }

    public func playNext(
        url: URL,
        title: String? = nil,
        normalizationGain: Double? = nil,
        playbackEndTime: TimeInterval? = nil,
        playbackAnalysisVersion: Int? = nil
    ) {
        var queue = state.queue
        queue.playNext(
            PlaybackQueueItem(
                url: url,
                title: title,
                normalizationGain: normalizationGain,
                playbackEndTime: playbackEndTime,
                playbackAnalysisVersion: playbackAnalysisVersion
            )
        )
        state.queue = queue
        preloadNextItemIfNeeded()
    }

    public func playQueueItem(id: PlaybackQueueItem.ID) throws {
        var queue = state.queue
        queue.setCurrentItem(id: id)
        state.queue = queue

        guard let item = queue.currentItem else {
            throw fail(.noCurrentItem)
        }

        try load(item, autoplay: true)
    }

    public func removeFromQueue(id: PlaybackQueueItem.ID) {
        let wasCurrentItem = state.currentItem?.id == id
        let shouldAutoplay = state.isPlaying
        var queue = state.queue
        _ = queue.remove(id: id)
        state.queue = queue

        guard wasCurrentItem else {
            preloadNextItemIfNeeded()
            return
        }
        guard let item = queue.currentItem else {
            unload()
            return
        }

        do {
            try load(item, autoplay: shouldAutoplay)
        } catch {
            state.status = .failed(error.localizedDescription)
        }
    }

    public func moveQueueItem(id: PlaybackQueueItem.ID, by offset: Int) {
        var queue = state.queue
        queue.moveItem(id: id, by: offset)
        state.queue = queue
        preloadNextItemIfNeeded()
    }

    public func moveQueueItem(id: PlaybackQueueItem.ID, to index: Int) {
        var queue = state.queue
        queue.moveItem(id: id, to: index)
        state.queue = queue
        preloadNextItemIfNeeded()
    }

    public func clearUpcomingQueue() {
        var queue = state.queue
        queue.removeUpcoming()
        state.queue = queue
        preloadNextItemIfNeeded()
    }

    public func play() throws {
        guard audioFile != nil else {
            guard let item = state.queue.currentItem else {
                throw fail(.noCurrentItem)
            }
            try load(item, autoplay: true)
            return
        }

        if !engine.isRunning {
            try engine.start()
        }

        if shouldRestartFinishedItem {
            schedule(from: 0)
            state.currentTime = 0
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }

        preloadNextItemIfNeeded()
        state.status = .playing
        startProgressTimer()
    }

    public func pause() {
        updateCurrentTimeFromPlayer(advancesAtEnd: false)
        playerNode.pause()
        state.status = .paused
        stopProgressTimer()
    }

    public func stop() {
        invalidateScheduledSegment()
        playerNode.stop()
        clearPreloadCache()
        loadedFramePosition = 0
        scheduledStartFrame = 0
        state.currentTime = 0
        state.status = .stopped
        stopProgressTimer()
    }

    public func seek(to time: TimeInterval, autoplay: Bool? = nil) throws {
        guard let audioFile else {
            throw fail(.noCurrentItem)
        }

        let shouldPlay = autoplay ?? state.isPlaying
        let clampedTime = min(max(time, 0), state.duration)
        let frame = AVAudioFramePosition(clampedTime * audioFile.processingFormat.sampleRate)
        schedule(from: frame)
        state.currentTime = clampedTime

        if shouldPlay {
            try play()
        } else {
            state.status = .paused
        }
    }

    public func next(autoplay: Bool = true) throws {
        var queue = state.queue
        guard let item = queue.advanceToNext() else { return }
        state.queue = queue
        try load(item, autoplay: autoplay)
    }

    public func previous(autoplay: Bool = true) throws {
        var queue = state.queue

        if state.currentTime > 3 {
            try seek(to: 0, autoplay: autoplay)
            return
        }

        guard let item = queue.advanceToPrevious() else {
            try seek(to: 0, autoplay: autoplay)
            return
        }

        state.queue = queue
        try load(item, autoplay: autoplay)
    }

    public func setShuffleEnabled(_ isEnabled: Bool) {
        var queue = state.queue
        queue.setShuffled(isEnabled)
        state.queue = queue
        preloadNextItemIfNeeded()
    }

    public func toggleShuffle() {
        setShuffleEnabled(!state.queue.isShuffled)
    }

    public func toggleRepeatMode() {
        state.repeatMode = state.repeatMode.next
    }

    public func setProfile(_ profile: PlaybackProfile) {
        state.profile = profile
        apply(profile)
    }

    public func setNightcoreEnabled(_ isEnabled: Bool) {
        setProfile(state.profile.withNightcoreEnabled(isEnabled))
    }

    public func setSpeed(_ speed: Double) {
        var profile = state.profile
        profile.speed = speed
        profile.name = profile.isNightcoreEnabled ? "Nightcore" : "Custom"
        setProfile(profile)
    }

    public func setSpeedPreset(_ preset: PlaybackSpeedPreset) {
        var profile = state.profile
        profile.speed = preset.speed
        profile.pitchSemitones = 0.0
        profile.isNightcoreEnabled = preset.speed > PlaybackProfile.normalSpeed
        profile.isPitchLinkedToSpeed = profile.isNightcoreEnabled
        profile.isPitchPreserved = !profile.isNightcoreEnabled
        profile.name = profile.isNightcoreEnabled ? "Nightcore" : "Normal"
        setProfile(profile)
    }

    public func setPitchOffset(semitones: Double) {
        var profile = state.profile
        profile.pitchSemitones = semitones
        profile.name = profile.isNightcoreEnabled ? "Nightcore" : "Custom"
        setProfile(profile)
    }

    public func setPitchLinkedToSpeed(_ isLinked: Bool) {
        var profile = state.profile
        profile.isPitchLinkedToSpeed = isLinked
        if isLinked {
            profile.isPitchPreserved = false
        }
        setProfile(profile)
    }

    public func setPitchPreserved(_ isPreserved: Bool) {
        var profile = state.profile
        profile.isPitchPreserved = isPreserved
        if isPreserved {
            profile.isPitchLinkedToSpeed = false
        }
        setProfile(profile)
    }

    public func setVolume(_ volume: Double) {
        let clampedVolume = min(max(volume, 0), 1)
        previewVolume(clampedVolume)
        guard abs(state.volume - clampedVolume) > 0.0005 else { return }
        state.volume = clampedVolume
    }

    public func previewVolume(_ volume: Double) {
        engine.mainMixerNode.outputVolume = Self.mixerOutputVolume(for: volume)
    }

    public func adjustVolume(by delta: Double) {
        setVolume(state.volume + delta)
    }

    private func configureAudioSession() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
#endif
    }

    private func load(_ item: PlaybackQueueItem, autoplay: Bool) throws {
        let preparedItem = preparedItems[item.id]?.matches(item) == true ? preparedItems[item.id] : nil
        beginLoading(item)

        guard FileManager.default.fileExists(atPath: item.url.path) else {
            throw fail(.fileDoesNotExist(item.url))
        }

        do {
            let file = try preparedItem?.file ?? AVAudioFile(forReading: item.url)
            audioFile = file
            playbackEndFrame = preparedItem?.playbackEndFrame ?? Self.playbackEndFrame(for: item.playbackEndTime, file: file)
            removePreparedItem(id: item.id)
            state.duration = TimeInterval(playbackEndFrame) / file.processingFormat.sampleRate
            applyNormalizationGain(item.normalizationGain)
            startPlaybackAnalysisIfNeeded(for: item)
            schedule(from: 0)
            preloadNextItemIfNeeded()
            state.status = .ready

            if autoplay {
                try play()
            }
        } catch {
            throw fail(.failedToReadFile(error.localizedDescription))
        }
    }

    private func beginLoading(_ item: PlaybackQueueItem) {
        stopProgressTimer()
        invalidateScheduledSegment()
        playbackAnalysisTask?.cancel()
        cancelPreloadTask()
        playerNode.stop()
        audioFile = nil
        loadedFramePosition = 0
        scheduledStartFrame = 0
        playbackEndFrame = 0
        applyNormalization(.neutral)
        state.currentItem = item
        state.currentTime = 0
        state.duration = 0
        state.status = .loading
    }

    private func unload() {
        stop()
        audioFile = nil
        playbackEndFrame = 0
        clearPreloadCache()
        state.currentItem = nil
        state.duration = 0
        state.status = .idle
    }

    private func configureEngine() {
        engine.attach(playerNode)
        engine.attach(normalizationGain)
        engine.attach(varispeed)
        engine.attach(timePitch)
        engine.connect(playerNode, to: normalizationGain, format: nil)
        engine.connect(normalizationGain, to: varispeed, format: nil)
        engine.connect(varispeed, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        timePitch.overlap = 32.0
        engine.mainMixerNode.outputVolume = Self.mixerOutputVolume(for: state.volume)
        engine.prepare()
    }

    private func apply(_ profile: PlaybackProfile) {
        let speed = Float(profile.clampedSpeed)
        let manualPitchCents = Float(profile.pitchSemitones * 100.0)
        let usesLinkedVarispeed = profile.isPitchLinkedToSpeed && !profile.isPitchPreserved

        if usesLinkedVarispeed {
            // True Nightcore is varispeed playback: rate and pitch rise together without time-stretch artifacts.
            varispeed.rate = speed
            varispeed.bypass = isNeutralRate(speed)
            timePitch.rate = 1.0
            timePitch.pitch = manualPitchCents
            timePitch.bypass = isNeutralPitch(manualPitchCents)
        } else {
            varispeed.rate = 1.0
            varispeed.bypass = true
            timePitch.rate = speed
            timePitch.pitch = manualPitchCents
            timePitch.bypass = isNeutralRate(speed) && isNeutralPitch(manualPitchCents)
        }
    }

    private static func mixerOutputVolume(for volume: Double) -> Float {
        Float(min(max(volume, 0), 1)) * outputHeadroom
    }

    private func applyNormalizationGain(_ gain: Double?) {
        let normalization = gain.map { PlaybackNormalization(linearGain: Float($0)) } ?? .neutral
        applyNormalization(normalization)
    }

    private func applyNormalization(_ normalization: PlaybackNormalization) {
        normalizationGain.globalGain = normalization.gainDecibels
        normalizationGain.bypass = abs(normalization.gainDecibels) < 0.01
    }

    private func applyPlaybackEndTime(_ playbackEndTime: TimeInterval?) {
        guard let audioFile else { return }

        let newEndFrame = Self.playbackEndFrame(for: playbackEndTime, file: audioFile)
        let currentEndFrame = effectiveEndFrame
        guard newEndFrame > 0, newEndFrame < currentEndFrame else { return }

        playbackEndFrame = newEndFrame
        state.duration = TimeInterval(newEndFrame) / audioFile.processingFormat.sampleRate
        state.currentTime = min(state.currentTime, state.duration)

        if loadedFramePosition >= newEndFrame {
            finishCurrentItem()
        }
    }

    private func startPlaybackAnalysisIfNeeded(for item: PlaybackQueueItem) {
        playbackAnalysisTask?.cancel()
        guard item.normalizationGain == nil || item.playbackAnalysisVersion != PlaybackAnalysis.currentVersion else { return }

        let itemID = item.id
        let url = item.url
        playbackAnalysisTask = Task(priority: .userInitiated) { [weak self] in
            let analysis = await PlaybackNormalizationAnalyzer.shared.analysis(for: url)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, self.state.currentItem?.id == itemID else { return }
                if item.normalizationGain == nil {
                    self.applyNormalization(analysis.normalization)
                }
                if item.playbackAnalysisVersion != PlaybackAnalysis.currentVersion {
                    self.applyPlaybackEndTime(analysis.playbackEndTime)
                }
            }
        }
    }

    private func preloadNextItemIfNeeded() {
        guard audioFile != nil else {
            clearPreloadCache()
            return
        }

        let candidates = upcomingPreloadCandidates()
        guard !candidates.isEmpty else {
            clearPreloadCache()
            return
        }

        prunePreparedItems(keeping: candidates)

        let itemsToPrepare = candidates.filter { item in
            FileManager.default.fileExists(atPath: item.url.path) &&
                preparedItems[item.id]?.matches(item) != true
        }

        guard !itemsToPrepare.isEmpty else {
            return
        }

        cancelPreloadTask()
        let generation = preloadGeneration

        preloadTask = Task.detached(priority: .utility) { [weak self] in
            for item in itemsToPrepare {
                guard !Task.isCancelled else { return }
                guard let file = try? AVAudioFile(forReading: item.url) else { continue }

                let preparedItem = PreparedPlaybackItem(
                    itemID: item.id,
                    url: item.url,
                    file: file,
                    playbackEndFrame: Self.playbackEndFrame(for: item.playbackEndTime, file: file)
                )

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self,
                          self.preloadGeneration == generation,
                          self.isUpcomingPreloadCandidate(item) else {
                        return
                    }

                    self.storePreparedItem(preparedItem, for: item)
                }

                await Task.yield()
            }
        }
    }

    private func upcomingPreloadCandidates() -> [PlaybackQueueItem] {
        guard let currentIndex = state.queue.currentIndex else { return [] }
        let startIndex = currentIndex + 1
        guard state.queue.items.indices.contains(startIndex),
              preloadLookaheadCount > 0 else {
            return []
        }

        let endIndex = min(startIndex + preloadLookaheadCount, state.queue.items.endIndex)
        return Array(state.queue.items[startIndex..<endIndex])
    }

    private func isUpcomingPreloadCandidate(_ item: PlaybackQueueItem) -> Bool {
        upcomingPreloadCandidates().contains { candidate in
            candidate.id == item.id && candidate.url.standardizedFileURL.path == item.url.standardizedFileURL.path
        }
    }

    private func storePreparedItem(_ preparedItem: PreparedPlaybackItem, for item: PlaybackQueueItem) {
        preparedItems[item.id] = preparedItem
        preparedItemOrder.removeAll { $0 == item.id }
        preparedItemOrder.append(item.id)
        trimPreparedItemsToLimit()
    }

    private func prunePreparedItems(keeping candidates: [PlaybackQueueItem]) {
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        preparedItems = preparedItems.filter { id, preparedItem in
            guard let candidate = candidatesByID[id] else { return false }
            return preparedItem.matches(candidate)
        }
        preparedItemOrder.removeAll { preparedItems[$0] == nil }
        trimPreparedItemsToLimit()
    }

    private func removePreparedItem(id: PlaybackQueueItem.ID) {
        preparedItems[id] = nil
        preparedItemOrder.removeAll { $0 == id }
    }

    private func trimPreparedItemsToLimit() {
        let limit = max(0, min(preloadLookaheadCount, Self.maximumPreloadedItems))
        while preparedItemOrder.count > limit, let oldestID = preparedItemOrder.first {
            preparedItemOrder.removeFirst()
            preparedItems[oldestID] = nil
        }
    }

    private func cancelPreloadTask() {
        preloadGeneration += 1
        preloadTask?.cancel()
        preloadTask = nil
    }

    private func clearPreloadCache() {
        cancelPreloadTask()
        preparedItems.removeAll()
        preparedItemOrder.removeAll()
    }

    private static func clampedPreloadLookaheadCount(_ count: Int) -> Int {
        min(max(count, 0), maximumPreloadedItems)
    }

    private func isNeutralRate(_ rate: Float) -> Bool {
        abs(rate - 1.0) < 0.0001
    }

    private func isNeutralPitch(_ pitchCents: Float) -> Bool {
        abs(pitchCents) < 0.1
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let audioFile else { return }

        activeScheduleID += 1
        let scheduleID = activeScheduleID
        let itemID = state.currentItem?.id
        activeScheduleItemID = itemID

        playerNode.stop()
        let endFrame = effectiveEndFrame
        let clampedFrame = min(max(frame, 0), endFrame)
        let remainingFrames = max(endFrame - clampedFrame, 0)
        let frameCount = AVAudioFrameCount(min(Int64(UInt32.max), remainingFrames))

        loadedFramePosition = clampedFrame
        scheduledStartFrame = clampedFrame

        guard frameCount > 0 else { return }

        playerNode.scheduleSegment(
            audioFile,
            startingFrame: clampedFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScheduledSegmentCompleted(scheduleID: scheduleID, itemID: itemID)
            }
        }
    }

    private func invalidateScheduledSegment() {
        activeScheduleID += 1
        activeScheduleItemID = nil
    }

    private func handleScheduledSegmentCompleted(scheduleID: Int, itemID: PlaybackQueueItem.ID?) {
        guard state.status == .playing else { return }
        guard scheduleID == activeScheduleID, itemID == activeScheduleItemID else { return }
        guard itemID == state.currentItem?.id else { return }
        updateCurrentTimeFromPlayer(advancesAtEnd: false)
        guard playbackHasReachedEnd() else { return }

        finishCurrentItem()
    }

    private func finishCurrentItem() {
        guard state.status == .playing else { return }
        invalidateScheduledSegment()

        switch state.repeatMode {
        case .one:
            try? seek(to: 0, autoplay: true)
        case .none where state.queue.hasNext:
            try? next(autoplay: true)
        case .none:
            restartQueue()
        }
    }

    private func restartQueue() {
        var queue = state.queue
        guard let item = queue.moveToStart() else {
            stopAtEnd()
            return
        }
        state.queue = queue
        try? load(item, autoplay: true)
    }

    private func stopAtEnd() {
        playerNode.stop()
        loadedFramePosition = effectiveEndFrame
        scheduledStartFrame = loadedFramePosition
        state.status = .stopped
        state.currentTime = state.duration
        stopProgressTimer()
    }

    private func startProgressTimer() {
        guard progressTimer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCurrentTimeFromPlayer(advancesAtEnd: true)
            }
        }
        timer.tolerance = 0.05
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateCurrentTimeFromPlayer(advancesAtEnd: Bool) {
        guard let audioFile else { return }

        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
            let currentFrame = scheduledStartFrame + AVAudioFramePosition(playerTime.sampleTime)
            loadedFramePosition = min(currentFrame, effectiveEndFrame)
            state.currentTime = TimeInterval(loadedFramePosition) / audioFile.processingFormat.sampleRate
        } else {
            state.currentTime = TimeInterval(loadedFramePosition) / audioFile.processingFormat.sampleRate
        }

        if advancesAtEnd, state.status == .playing, playbackHasReachedEnd(allowTolerance: false) {
            finishCurrentItem()
        }
    }

    private func playbackHasReachedEnd(allowTolerance: Bool = true) -> Bool {
        guard let audioFile, state.duration > 0 else { return false }

        let sampleRate = audioFile.processingFormat.sampleRate
        let toleranceSeconds = allowTolerance ? 0.15 : 0
        let toleranceFrames = AVAudioFramePosition(max(sampleRate * toleranceSeconds, 0))
        let endingFrame = max(effectiveEndFrame - toleranceFrames, 0)
        let hasReachedEndingFrame = loadedFramePosition >= endingFrame
        let hasReachedEndingTime = state.currentTime >= max(state.duration - toleranceSeconds, 0)
        return hasReachedEndingFrame || hasReachedEndingTime
    }

    private var shouldRestartFinishedItem: Bool {
        guard audioFile != nil, state.duration > 0 else { return false }
        return loadedFramePosition >= effectiveEndFrame || state.currentTime >= state.duration
    }

    private var effectiveEndFrame: AVAudioFramePosition {
        guard let audioFile else { return playbackEndFrame }
        guard playbackEndFrame > 0 else { return audioFile.length }
        return min(playbackEndFrame, audioFile.length)
    }

    nonisolated private static func playbackEndFrame(for playbackEndTime: TimeInterval?, file: AVAudioFile) -> AVAudioFramePosition {
        guard let playbackEndTime,
              playbackEndTime.isFinite,
              playbackEndTime > 0 else {
            return file.length
        }

        let frame = AVAudioFramePosition(playbackEndTime * file.processingFormat.sampleRate)
        return min(max(frame, 1), file.length)
    }

    private func fail(_ error: PlayerEngineError) -> PlayerEngineError {
        state.status = .failed(error.localizedDescription)
        return error
    }
}

private struct PreparedPlaybackItem: @unchecked Sendable {
    let itemID: PlaybackQueueItem.ID
    let url: URL
    let file: AVAudioFile
    let playbackEndFrame: AVAudioFramePosition

    func matches(_ item: PlaybackQueueItem) -> Bool {
        item.id == itemID &&
            item.url.standardizedFileURL.path == url.standardizedFileURL.path
    }
}

public struct PlaybackNormalization: Equatable, Sendable {
    public static let neutral = PlaybackNormalization(linearGain: 1.0)

    public let linearGain: Float

    public var gainDecibels: Float {
        20.0 * Float(log10(Double(linearGain)))
    }

    public init(linearGain: Float) {
        if linearGain.isFinite, linearGain > 0 {
            self.linearGain = min(max(linearGain, 0.125), 2.0)
        } else {
            self.linearGain = Self.neutral.linearGain
        }
    }
}

public struct PlaybackAnalysis: Equatable, Sendable {
    public static let currentVersion = 1

    public let normalization: PlaybackNormalization
    public let playbackEndTime: TimeInterval?

    public init(normalization: PlaybackNormalization, playbackEndTime: TimeInterval?) {
        self.normalization = normalization
        self.playbackEndTime = playbackEndTime
    }
}

public actor PlaybackNormalizationAnalyzer {
    public static let shared = PlaybackNormalizationAnalyzer()

    private static let targetRMS: Float = 0.12589254 // -18 dBFS
    private static let peakCeiling: Float = 0.89125094 // -1 dBFS
    private static let maxBoost: Float = 1.9952623 // +6 dB
    private static let minGain: Float = 0.12589254 // -18 dB
    private static let frameCapacity: AVAudioFrameCount = 32_768
    private static let trailingSilenceWindowDuration = 0.20
    private static let minimumTrailingSilenceDuration = 3.0
    private static let minimumSkippedSilenceDuration = 1.5
    private static let trailingSilenceSafetyPad = 1.0
    private static let trailingSilenceRMS: Float = 0.0005623413 // -65 dBFS
    private static let trailingSilencePeak: Float = 0.001 // -60 dBFS
    private static let yieldAfterBufferCount = 8

    private var cache: [String: PlaybackAnalysis] = [:]

    public func normalization(for url: URL) async -> PlaybackNormalization {
        let analysis = await analysis(for: url)
        return analysis.normalization
    }

    public func analysis(for url: URL) async -> PlaybackAnalysis {
        let key = cacheKey(for: url)
        if let cached = cache[key] {
            return cached
        }

        let taggedNormalization = await taggedNormalization(for: url)
        let scannedAnalysis = await scannedAnalysis(for: url)
        let analysis = PlaybackAnalysis(
            normalization: taggedNormalization ?? scannedAnalysis?.normalization ?? .neutral,
            playbackEndTime: scannedAnalysis?.playbackEndTime
        )
        cache[key] = analysis
        return analysis
    }

    private func taggedNormalization(for url: URL) async -> PlaybackNormalization? {
        let asset = AVURLAsset(url: url)
        let metadata = ((try? await asset.load(.commonMetadata)) ?? []) + ((try? await asset.load(.metadata)) ?? [])
        guard let gainDecibels = await metadataNumber(
            in: metadata,
            matching: ["replaygaintrackgain", "replaygainalbumgain"]
        ) else {
            return nil
        }

        var gain = Float(pow(10.0, gainDecibels / 20.0))
        if let peak = await metadataNumber(in: metadata, matching: ["replaygaintrackpeak", "replaygainalbumpeak"]),
           peak > 0 {
            gain = min(gain, Self.peakCeiling / Float(peak))
        }

        return PlaybackNormalization(linearGain: gain)
    }

    private func scannedAnalysis(for url: URL) async -> PlaybackAnalysis? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard format.sampleRate > 0, file.length > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.frameCapacity) else {
            return nil
        }

        let channelCount = max(Int(format.channelCount), 1)
        let windowFrameLimit = max(Int(format.sampleRate * Self.trailingSilenceWindowDuration), 1)
        var sumSquares = 0.0
        var peak: Float = 0
        var sampleCount = 0
        var absoluteFrame: AVAudioFramePosition = 0
        var lastAudibleFrame: AVAudioFramePosition = 0
        var windowSumSquares = 0.0
        var windowPeak: Float = 0
        var windowFrameCount = 0
        var buffersRead = 0

        func finishSilenceWindow() {
            guard windowFrameCount > 0 else { return }

            let windowSampleCount = max(windowFrameCount * channelCount, 1)
            let windowRMS = Float(sqrt(windowSumSquares / Double(windowSampleCount)))
            let isSilent = windowRMS.isFinite &&
                windowRMS <= Self.trailingSilenceRMS &&
                windowPeak <= Self.trailingSilencePeak

            if !isSilent {
                lastAudibleFrame = absoluteFrame
            }

            windowSumSquares = 0
            windowPeak = 0
            windowFrameCount = 0
        }

        func addFrame(sum frameSumSquares: Double, peak framePeak: Float) {
            sumSquares += frameSumSquares
            peak = max(peak, framePeak)
            sampleCount += channelCount

            windowSumSquares += frameSumSquares
            windowPeak = max(windowPeak, framePeak)
            windowFrameCount += 1
            absoluteFrame += 1

            if windowFrameCount >= windowFrameLimit {
                finishSilenceWindow()
            }
        }

        while !Task.isCancelled {
            do {
                try file.read(into: buffer, frameCount: buffer.frameCapacity)
            } catch {
                return nil
            }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }
            guard let channelData = buffer.floatChannelData else { return nil }

            if format.isInterleaved {
                let samples = channelData[0]
                for frame in 0..<frameLength {
                    var frameSumSquares = 0.0
                    var framePeak: Float = 0
                    let sampleBaseIndex = frame * channelCount

                    for channel in 0..<channelCount {
                        let sample = samples[sampleBaseIndex + channel]
                        guard sample.isFinite else { continue }

                        let absoluteSample = abs(sample)
                        framePeak = max(framePeak, absoluteSample)
                        frameSumSquares += Double(sample) * Double(sample)
                    }

                    addFrame(sum: frameSumSquares, peak: framePeak)
                }
            } else {
                for frame in 0..<frameLength {
                    var frameSumSquares = 0.0
                    var framePeak: Float = 0

                    for channel in 0..<channelCount {
                        let samples = channelData[channel]
                        let sample = samples[frame]
                        guard sample.isFinite else { continue }

                        let absoluteSample = abs(sample)
                        framePeak = max(framePeak, absoluteSample)
                        frameSumSquares += Double(sample) * Double(sample)
                    }

                    addFrame(sum: frameSumSquares, peak: framePeak)
                }
            }

            buffersRead += 1
            if buffersRead.isMultiple(of: Self.yieldAfterBufferCount) {
                await Task.yield()
            }
        }

        finishSilenceWindow()

        guard sampleCount > 0 else { return nil }
        let rms = Float(sqrt(sumSquares / Double(sampleCount)))
        guard rms.isFinite, rms > 0 else {
            return PlaybackAnalysis(normalization: .neutral, playbackEndTime: nil)
        }

        var gain = Self.targetRMS / rms
        if peak.isFinite, peak > 0 {
            gain = min(gain, Self.peakCeiling / peak)
        }
        gain = min(max(gain, Self.minGain), Self.maxBoost)

        if abs(20.0 * log10(Double(gain))) < 0.1 {
            gain = 1.0
        }

        return PlaybackAnalysis(
            normalization: PlaybackNormalization(linearGain: gain),
            playbackEndTime: Self.conservativePlaybackEndTime(
                totalFrames: absoluteFrame,
                lastAudibleFrame: lastAudibleFrame,
                sampleRate: format.sampleRate
            )
        )
    }

    private static func conservativePlaybackEndTime(
        totalFrames: AVAudioFramePosition,
        lastAudibleFrame: AVAudioFramePosition,
        sampleRate: Double
    ) -> TimeInterval? {
        guard sampleRate > 0, totalFrames > 0, lastAudibleFrame > 0 else { return nil }

        let minimumSilentTailFrames = AVAudioFramePosition(sampleRate * minimumTrailingSilenceDuration)
        let safetyPadFrames = AVAudioFramePosition(sampleRate * trailingSilenceSafetyPad)
        let minimumSkippedFrames = AVAudioFramePosition(sampleRate * minimumSkippedSilenceDuration)
        let paddedEndFrame = min(lastAudibleFrame + safetyPadFrames, totalFrames)
        let silentTailFrames = totalFrames - lastAudibleFrame
        let skippedFrames = totalFrames - paddedEndFrame

        guard silentTailFrames >= minimumSilentTailFrames,
              skippedFrames >= minimumSkippedFrames else {
            return nil
        }

        let endTime = TimeInterval(paddedEndFrame) / sampleRate
        return endTime.isFinite && endTime > 0 ? endTime : nil
    }

    private func metadataNumber(in metadata: [AVMetadataItem], matching tokens: [String]) async -> Double? {
        for item in metadata {
            let key = normalizedMetadataKey(for: item)
            guard tokens.contains(where: { key.contains($0) }) else { continue }

            if let stringValue = try? await item.load(.stringValue),
               let number = Self.firstNumber(in: stringValue) {
                return number
            }

            if let numberValue = try? await item.load(.numberValue) {
                return numberValue.doubleValue
            }
        }

        return nil
    }

    private func normalizedMetadataKey(for item: AVMetadataItem) -> String {
        [
            item.commonKey?.rawValue,
            item.identifier?.rawValue,
            item.keySpace?.rawValue,
            item.key.map { String(describing: $0) }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
    }

    private func cacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let fileSize = values?.fileSize ?? 0
        return "\(url.standardizedFileURL.path)|\(fileSize)|\(modifiedAt)"
    }

    private static func firstNumber(in string: String) -> Double? {
        string
            .firstMatch(of: /[-+]?\d+(?:\.\d+)?/)
            .flatMap { Double($0.output) }
    }
}

#if canImport(MediaPlayer)
@MainActor
private final class SystemNowPlayingController {
    private weak var player: PlayerEngine?
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var lastPublishedState: PlaybackState?

    init(player: PlayerEngine) {
        self.player = player
    }

    func activate() {
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.perform { try $0.play() }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.perform { $0.pause() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.perform { player in
                if player.state.isPlaying {
                    player.pause()
                } else {
                    try player.play()
                }
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.perform { try $0.next() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.perform { try $0.previous() }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            self?.perform { player in
                try player.seek(to: player.state.sourceTime(forSpeedAdjustedTime: event.positionTime))
            }
            return .success
        }
    }

    func updateIfNeeded(from oldState: PlaybackState, to state: PlaybackState) {
        guard shouldUpdateNowPlaying(from: lastPublishedState ?? oldState, to: state) else { return }
        update(with: state)
    }

    func update(with state: PlaybackState) {
        lastPublishedState = state

        guard let currentItem = state.currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let playbackRate = state.isPlaying ? 1.0 : 0.0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentItem.title ?? currentItem.url.deletingPathExtension().lastPathComponent,
            MPMediaItemPropertyAlbumTitle: currentItem.url.deletingLastPathComponent().lastPathComponent,
            MPMediaItemPropertyPlaybackDuration: state.speedAdjustedDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.speedAdjustedCurrentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]

        info[MPMediaItemPropertyArtist] = "Nightwing"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func shouldUpdateNowPlaying(from oldState: PlaybackState, to state: PlaybackState) -> Bool {
        if oldState.currentItem?.id != state.currentItem?.id {
            return true
        }

        if oldState.status != state.status ||
            oldState.duration != state.duration ||
            oldState.profile != state.profile {
            return true
        }

        return abs(oldState.speedAdjustedCurrentTime - state.speedAdjustedCurrentTime) >= 1.0
    }

    nonisolated private func perform(_ action: @escaping @MainActor (PlayerEngine) throws -> Void) {
        Task { @MainActor [weak self] in
            guard let player = self?.player else { return }
            try? action(player)
        }
    }
}
#endif
