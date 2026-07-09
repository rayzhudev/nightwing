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
        )
    ] + (1...12).map { semitoneOffset in
        let speed = speed(forSemitoneOffset: semitoneOffset)
        return PlaybackSpeedPreset(
            id: "plus-\(semitoneOffset)",
            title: "+\(semitoneOffset)",
            subtitle: speedLabel(forSemitoneOffset: semitoneOffset),
            speed: speed,
            semitoneOffset: semitoneOffset
        )
    }

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
        let clampedSpeed = min(max(speed, 0.25), 4.0)

        if let preset = speedPreset(matching: clampedSpeed) {
            return speedLabel(forSemitoneOffset: preset.semitoneOffset)
        }

        let roundedWholeSpeed = clampedSpeed.rounded()
        if abs(clampedSpeed - roundedWholeSpeed) <= 0.006 {
            return String(format: "%.0fx", roundedWholeSpeed)
        }

        let roundedCents = Int((1200.0 * log2(clampedSpeed)).rounded())
        return "≈\(powerOfTwoLabel(numerator: roundedCents, denominator: 1200))x"
    }

    public static func speedLabel(forSemitoneOffset semitoneOffset: Int) -> String {
        powerOfTwoLabel(numerator: semitoneOffset, denominator: 12) + "x"
    }

    private static func powerOfTwoLabel(numerator: Int, denominator: Int) -> String {
        guard numerator != 0 else { return "1" }
        guard numerator != denominator else { return "2" }

        let divisor = greatestCommonDivisor(abs(numerator), abs(denominator))
        let simplifiedNumerator = numerator / divisor
        let simplifiedDenominator = denominator / divisor

        if simplifiedNumerator == 1 && simplifiedDenominator == 2 {
            return "√2"
        }

        if simplifiedDenominator == 1 {
            return "2^\(simplifiedNumerator)"
        }

        return "2^{\(simplifiedNumerator)/\(simplifiedDenominator)}"
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs

        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }

        return max(a, 1)
    }
}
