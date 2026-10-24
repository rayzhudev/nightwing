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
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):([0-5]\d)(?:[\.:](\d{1,3}))?\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"^\[offset:([+-]?\d+)\]$"#, options: .caseInsensitive)
        var offset: TimeInterval = 0
        var timed: [(TimeInterval, String)] = []
        for raw in value.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = offsetPattern.firstMatch(in: line, range: range),
               let numberRange = Range(match.range(at: 1), in: line),
               let milliseconds = Double(line[numberRange]) {
                offset = milliseconds / 1000
                continue
            }
            let matches = timestamp.matches(in: line, range: range)
            guard let first = matches.first, first.range.location == 0 else { continue }
            // Only leading timestamp tags are timing; brackets within lyrics are text.
            var end = 0
            let leading = matches.prefix { match in
                guard match.range.location == end else { return false }
                end = NSMaxRange(match.range)
                return true
            }
            let text = (line as NSString).substring(from: end).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for match in leading {
                let string = line as NSString
                let minutes = Double(string.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(string.substring(with: match.range(at: 2))) ?? 0
                let fractionRange = match.range(at: 3)
                let fraction = fractionRange.location == NSNotFound ? 0 :
                    (Double(string.substring(with: fractionRange)) ?? 0) / pow(10, Double(fractionRange.length))
                timed.append((minutes * 60 + seconds + fraction, text))
            }
        }
        // Positive LRC offsets advance the display relative to the audio.
        var sorted: [(time: TimeInterval, text: String, order: Int)] = []
        for (index, item) in timed.enumerated() {
            sorted.append((time: max(0, item.0 - offset), text: item.1, order: index))
        }
        sorted.sort { lhs, rhs in
            if lhs.time == rhs.time { return lhs.order < rhs.order }
            return lhs.time < rhs.time
        }
        var result: [LyricsLine] = []
        for (index, item) in sorted.enumerated() {
            let next = sorted.dropFirst(index + 1).first { $0.time > item.time }
            let end = next?.time ?? max(trackDuration, item.time + 2)
            result.append(LyricsLine(startTime: item.time, endTime: max(end, item.time + 0.2), text: item.text))
        }
        return result
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
