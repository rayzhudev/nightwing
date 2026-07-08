import Foundation

public enum PlaybackStatus: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case stopped
    case failed(String)
}

public enum PlaybackRepeatMode: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case one

    public var next: PlaybackRepeatMode {
        switch self {
        case .none:
            return .one
        case .one:
            return .none
        }
    }
}

public struct PlaybackState: Equatable, Sendable {
    public var status: PlaybackStatus
    public var currentItem: PlaybackQueueItem?
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var volume: Double
    public var profile: PlaybackProfile
    public var queue: PlaybackQueue
    public var repeatMode: PlaybackRepeatMode

    public init(
        status: PlaybackStatus = .idle,
        currentItem: PlaybackQueueItem? = nil,
        currentTime: TimeInterval = 0,
        duration: TimeInterval = 0,
        volume: Double = 0.85,
        profile: PlaybackProfile = .normal,
        queue: PlaybackQueue = PlaybackQueue(),
        repeatMode: PlaybackRepeatMode = .none
    ) {
        self.status = status
        self.currentItem = currentItem
        self.currentTime = currentTime
        self.duration = duration
        self.volume = volume
        self.profile = profile
        self.queue = queue
        self.repeatMode = repeatMode
    }

    public var isPlaying: Bool {
        status == .playing
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    public var playbackDisplayRate: Double {
        max(profile.clampedSpeed, 0.01)
    }

    public var speedAdjustedCurrentTime: TimeInterval {
        currentTime / playbackDisplayRate
    }

    public var speedAdjustedDuration: TimeInterval {
        duration / playbackDisplayRate
    }

    public var speedAdjustedRemainingTime: TimeInterval {
        max(duration - currentTime, 0) / playbackDisplayRate
    }

    public func sourceTime(forSpeedAdjustedTime time: TimeInterval) -> TimeInterval {
        time * playbackDisplayRate
    }
}

public enum PlayerEngineError: LocalizedError, Equatable {
    case fileDoesNotExist(URL)
    case failedToReadFile(String)
    case noCurrentItem

    public var errorDescription: String? {
        switch self {
        case .fileDoesNotExist(let url):
            return "Audio file is unavailable: \(url.lastPathComponent)"
        case .failedToReadFile(let message):
            return "Could not read audio file: \(message)"
        case .noCurrentItem:
            return "No track is loaded."
        }
    }
}
