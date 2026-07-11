import Foundation

public actor CanonicalLyricsService {
    public init() {}

    private struct Record: Decodable {
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    public enum Result: Sendable {
        case synced([LyricsLine])
        case plain([String])
        case instrumental
    }

    public func lyrics(for track: Track) async throws -> Result? {
        guard let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
              !artist.isEmpty,
              let album = track.album?.trimmingCharacters(in: .whitespacesAndNewlines),
              !album.isEmpty,
              let duration = track.duration,
              duration > 0 else {
            return nil
        }

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Nightwing/1.0 (local music player)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        if httpResponse.statusCode == 404 { return nil }
        guard (200...299).contains(httpResponse.statusCode) else { return nil }

        let record = try JSONDecoder().decode(Record.self, from: data)
        if record.instrumental { return .instrumental }
        if let synced = record.syncedLyrics,
           !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = Self.parseLRC(synced, trackDuration: duration)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = record.plainLyrics {
            let lines = plain.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty { return .plain(lines) }
        }
        return nil
    }

    static func parseLRC(_ value: String, trackDuration: TimeInterval) -> [LyricsLine] {
        let pattern = #"^\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]\s*(.*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var timed: [(TimeInterval, String)] = []
        for rawLine in value.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            guard let match = expression.firstMatch(in: rawLine, range: range),
                  let minuteRange = Range(match.range(at: 1), in: rawLine),
                  let secondRange = Range(match.range(at: 2), in: rawLine),
                  let textRange = Range(match.range(at: 4), in: rawLine),
                  let minutes = Double(rawLine[minuteRange]),
                  let seconds = Double(rawLine[secondRange]) else { continue }
            let fraction: Double
            if let fractionRange = Range(match.range(at: 3), in: rawLine) {
                let digits = String(rawLine[fractionRange])
                fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
            } else {
                fraction = 0
            }
            let text = rawLine[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { timed.append((minutes * 60 + seconds + fraction, text)) }
        }
        return timed.enumerated().map { index, item in
            let end = index + 1 < timed.count ? timed[index + 1].0 : max(trackDuration, item.0 + 2)
            return LyricsLine(startTime: item.0, endTime: max(end, item.0 + 0.2), text: item.1)
        }
    }

    static func align(_ canonicalLines: [String], to transcript: [LyricsLine]) -> [LyricsLine] {
        guard !canonicalLines.isEmpty, !transcript.isEmpty else { return transcript }
        var result: [LyricsLine] = []
        var searchStart = 0
        for (lineIndex, text) in canonicalLines.enumerated() {
            let normalized = normalize(text)
            guard !normalized.isEmpty else { continue }
            let remainingLines = canonicalLines.count - lineIndex
            let searchEnd = max(searchStart, transcript.count - max(remainingLines - 1, 0))
            var bestIndex = searchStart
            var bestScore = -Double.infinity
            for index in searchStart..<max(searchEnd, searchStart + 1) where index < transcript.count {
                let score = similarity(normalized, normalize(transcript[index].text)) - Double(index - searchStart) * 0.015
                if score > bestScore { bestScore = score; bestIndex = index }
            }
            let timing = transcript[min(bestIndex, transcript.count - 1)]
            result.append(LyricsLine(startTime: timing.startTime, endTime: timing.endTime, text: text))
            searchStart = min(bestIndex + 1, transcript.count - 1)
        }
        for index in result.indices {
            if index + 1 < result.count { result[index].endTime = max(result[index + 1].startTime, result[index].startTime + 0.2) }
        }
        return result.isEmpty ? transcript : result
    }

    private static func normalize(_ value: String) -> [Substring] {
        value.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: \ .isWhitespace)
    }

    private static func similarity(_ lhs: [Substring], _ rhs: [Substring]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let left = Set(lhs.map(String.init))
        let right = Set(rhs.map(String.init))
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }
}
