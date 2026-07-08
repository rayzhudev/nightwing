import Foundation

public struct PlaybackSpeedPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let speed: Double
    public let semitoneOffset: Int

    public init(
        id: String,
        title: String,
        subtitle: String,
        speed: Double,
        semitoneOffset: Int
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.speed = speed
        self.semitoneOffset = semitoneOffset
    }
}

public struct PlaybackProfile: Codable, Equatable, Sendable {
    public static let normalSpeed: Double = 1.0
    public static let nightcoreSpeed: Double = sqrt(2.0)
    public static let nightcorePitchSemitones: Double = 6.0

    public static let speedPresets: [PlaybackSpeedPreset] = [
        PlaybackSpeedPreset(
            id: "normal",
            title: "1x",
            subtitle: "Original",
            speed: normalSpeed,
            semitoneOffset: 0
        ),
        PlaybackSpeedPreset(
            id: "plus-2",
            title: "+2",
            subtitle: "1.122x",
            speed: speed(forSemitoneOffset: 2),
            semitoneOffset: 2
        ),
        PlaybackSpeedPreset(
            id: "plus-3",
            title: "+3",
            subtitle: "1.189x",
            speed: speed(forSemitoneOffset: 3),
            semitoneOffset: 3
        ),
        PlaybackSpeedPreset(
            id: "plus-4",
            title: "+4",
            subtitle: "1.260x",
            speed: speed(forSemitoneOffset: 4),
            semitoneOffset: 4
        ),
        PlaybackSpeedPreset(
            id: "nightcore",
            title: "√2",
            subtitle: "1.414x, +6 st",
            speed: nightcoreSpeed,
            semitoneOffset: 6
        ),
        PlaybackSpeedPreset(
            id: "plus-7",
            title: "+7",
            subtitle: "1.498x",
            speed: speed(forSemitoneOffset: 7),
            semitoneOffset: 7
        ),
        PlaybackSpeedPreset(
            id: "plus-9",
            title: "+9",
            subtitle: "1.682x",
            speed: speed(forSemitoneOffset: 9),
            semitoneOffset: 9
        ),
        PlaybackSpeedPreset(
            id: "octave",
            title: "2x",
            subtitle: "+12 st",
            speed: speed(forSemitoneOffset: 12),
            semitoneOffset: 12
        )
    ]

    public static let normal = PlaybackProfile(
        name: "Normal",
        speed: normalSpeed,
        pitchSemitones: 0.0,
        isPitchLinkedToSpeed: false,
        isPitchPreserved: true,
        isNightcoreEnabled: false
    )

    public static let nightcore = PlaybackProfile(
        name: "Nightcore",
        speed: nightcoreSpeed,
        pitchSemitones: 0.0,
        isPitchLinkedToSpeed: true,
        isPitchPreserved: false,
        isNightcoreEnabled: true
    )

    public var name: String
    public var speed: Double
    public var pitchSemitones: Double
    public var isPitchLinkedToSpeed: Bool
    public var isPitchPreserved: Bool
    public var isNightcoreEnabled: Bool

    public init(
        name: String,
        speed: Double,
        pitchSemitones: Double,
        isPitchLinkedToSpeed: Bool,
        isPitchPreserved: Bool,
        isNightcoreEnabled: Bool
    ) {
        self.name = name
        self.speed = speed
        self.pitchSemitones = pitchSemitones
        self.isPitchLinkedToSpeed = isPitchLinkedToSpeed
        self.isPitchPreserved = isPitchPreserved
        self.isNightcoreEnabled = isNightcoreEnabled
    }

    public var clampedSpeed: Double {
        min(max(speed, 0.25), 4.0)
    }

    public var effectivePitchSemitones: Double {
        if isPitchPreserved {
            return pitchSemitones
        }

        if isPitchLinkedToSpeed {
            return Self.pitchSemitones(forSpeed: clampedSpeed) + pitchSemitones
        }

        return pitchSemitones
    }

    public var effectivePitchCents: Float {
        Float(effectivePitchSemitones * 100.0)
    }

    public var effectiveRate: Float {
        Float(clampedSpeed)
    }

    public func withNightcoreEnabled(_ isEnabled: Bool) -> PlaybackProfile {
        if isEnabled {
            return .nightcore
        }

        var profile = self
        profile.name = "Normal"
        profile.speed = Self.normalSpeed
        profile.pitchSemitones = 0.0
        profile.isPitchLinkedToSpeed = false
        profile.isPitchPreserved = true
        profile.isNightcoreEnabled = false
        return profile
    }

    public static func pitchSemitones(forSpeed speed: Double) -> Double {
        guard speed > 0 else { return 0.0 }
        return 12.0 * log2(speed)
    }

    public static func speed(forSemitoneOffset semitoneOffset: Int) -> Double {
        pow(2.0, Double(semitoneOffset) / 12.0)
    }

    public static func speedPreset(matching speed: Double, tolerance: Double = 0.006) -> PlaybackSpeedPreset? {
        speedPresets.first { abs($0.speed - speed) <= tolerance }
    }

    public static func speedLabel(for speed: Double) -> String {
        if let preset = speedPreset(matching: speed) {
            return preset.title
        }

        return String(format: "%.2fx", min(max(speed, 0.25), 4.0))
    }
}
