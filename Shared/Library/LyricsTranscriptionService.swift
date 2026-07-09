import Foundation

public struct LyricsTranscriptionService {
    public enum TranscriptionError: Error, LocalizedError, Sendable {
        case unsupportedPlatform
        case missingLocalRunner(String)
        case audioConversionFailed(String)
        case transcriptionFailed(String)
        case unreadableOutput
        case emptyTranscript

        public var errorDescription: String? {
            switch self {
            case .unsupportedPlatform:
                return "Lyrics generation is only available on macOS for now."
            case .missingLocalRunner(let path):
                return "Could not find the local transcription runner at \(path)."
            case .audioConversionFailed(let message):
                return "Could not prepare audio for lyrics: \(message)"
            case .transcriptionFailed(let message):
                return "Lyrics transcription failed: \(message)"
            case .unreadableOutput:
                return "The transcription output could not be read."
            case .emptyTranscript:
                return "The transcription did not contain any lyrics."
            }
        }
    }

    public struct Configuration: Sendable {
        public var pythonPath: String
        public var modelPath: String
        public var transcriptionSpeed: Double
        public var languageCode: String
        public var beamSize: Int
        public var modelName: String

        public init(
            pythonPath: String = "/Users/ray/OpenClaw/venvs/video-editing/bin/python",
            modelPath: String = "/Users/ray/.cache/huggingface/hub/models--Systran--faster-whisper-small/snapshots/536b0662742c02347bc0e980a01041f333bce120",
            transcriptionSpeed: Double = 1.15,
            languageCode: String = "en",
            beamSize: Int = 5,
            modelName: String = "Systran/faster-whisper-small"
        ) {
            self.pythonPath = pythonPath
            self.modelPath = modelPath
            self.transcriptionSpeed = transcriptionSpeed
            self.languageCode = languageCode
            self.beamSize = beamSize
            self.modelName = modelName
        }
    }

    private let configuration: Configuration
    private let fileManager: FileManager

    public init(configuration: Configuration = Configuration(), fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public func transcribe(track: Track, sourceURL: URL) async throws -> LyricsDocument {
        #if os(macOS)
        guard fileManager.fileExists(atPath: configuration.pythonPath) else {
            throw TranscriptionError.missingLocalRunner(configuration.pythonPath)
        }

        let workingDirectory = try makeWorkingDirectory()
        defer {
            try? fileManager.removeItem(at: workingDirectory)
        }

        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let wavURL = workingDirectory.appendingPathComponent("prepared.wav")
        try await prepareAudio(sourceURL: sourceURL, outputURL: wavURL)
        let outputURL = workingDirectory.appendingPathComponent("transcript.json")
        try await runTranscription(audioURL: wavURL, outputURL: outputURL)
        let lines = try decodedLines(from: outputURL)
        guard !lines.isEmpty else {
            throw TranscriptionError.emptyTranscript
        }

        let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return LyricsDocument(
            trackID: track.id,
            trackTitle: track.title,
            artist: track.artist,
            album: track.album,
            sourceFilePath: sourceURL.standardizedFileURL.path,
            sourceFileSize: values?.fileSize.map(Int64.init),
            sourceModifiedAt: values?.contentModificationDate,
            modelName: configuration.modelName,
            transcriptionSpeed: configuration.transcriptionSpeed,
            languageCode: configuration.languageCode,
            lines: lines
        )
        #else
        throw TranscriptionError.unsupportedPlatform
        #endif
    }

    #if os(macOS)
    private func makeWorkingDirectory() throws -> URL {
        let baseURL = fileManager.temporaryDirectory
            .appendingPathComponent("NightwingLyrics", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL
    }

    private func prepareAudio(sourceURL: URL, outputURL: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath())
        process.arguments = [
            "-y",
            "-v", "error",
            "-i", sourceURL.path,
            "-vn",
            "-ac", "1",
            "-af", "atempo=\(configuration.transcriptionSpeed),aresample=16000",
            outputURL.path
        ]

        let result = try await run(process)
        guard result.exitCode == 0 else {
            throw TranscriptionError.audioConversionFailed(result.standardError)
        }
    }

    private func ffmpegPath() -> String {
        [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ].first { fileManager.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/ffmpeg"
    }

    private func runTranscription(audioURL: URL, outputURL: URL) async throws {
        let script = """
import json
import sys
from faster_whisper import WhisperModel

model_path = sys.argv[1]
audio_path = sys.argv[2]
output_path = sys.argv[3]
speed = float(sys.argv[4])
language = sys.argv[5]
beam_size = int(sys.argv[6])

model = WhisperModel(model_path, device="cpu", compute_type="int8")
segments, info = model.transcribe(
    audio_path,
    language=language,
    beam_size=beam_size,
    word_timestamps=False,
    condition_on_previous_text=False,
)

rows = []
for segment in segments:
    text = segment.text.strip()
    if not text:
        continue
    rows.append({
        "start": float(segment.start) * speed,
        "end": float(segment.end) * speed,
        "text": text,
    })

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump({"segments": rows, "language": getattr(info, "language", language)}, handle, ensure_ascii=False)
"""

        let scriptURL = outputURL.deletingLastPathComponent().appendingPathComponent("transcribe.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.pythonPath)
        process.arguments = [
            scriptURL.path,
            configuration.modelPath,
            audioURL.path,
            outputURL.path,
            String(configuration.transcriptionSpeed),
            configuration.languageCode,
            String(configuration.beamSize)
        ]

        let result = try await run(process)
        guard result.exitCode == 0 else {
            throw TranscriptionError.transcriptionFailed(result.standardError)
        }
    }

    private func decodedLines(from outputURL: URL) throws -> [LyricsLine] {
        struct Output: Decodable {
            struct Segment: Decodable {
                let start: TimeInterval
                let end: TimeInterval
                let text: String
            }

            let segments: [Segment]
        }

        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw TranscriptionError.unreadableOutput
        }

        let data = try Data(contentsOf: outputURL)
        let output = try JSONDecoder().decode(Output.self, from: data)
        return output.segments.map {
            LyricsLine(
                startTime: max($0.start, 0),
                endTime: max($0.end, $0.start + 0.2),
                text: $0.text
            )
        }
    }

    private func run(_ process: Process) async throws -> (exitCode: Int32, standardError: String) {
        try await withCheckedThrowingContinuation { continuation in
            let standardError = Pipe()
            process.standardError = standardError
            process.terminationHandler = { completedProcess in
                let data = standardError.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (completedProcess.terminationStatus, message))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    #endif
}
