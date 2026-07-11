import Foundation

public struct LyricsTranscriptionService {
    public enum TranscriptionError: Error, LocalizedError, Sendable {
        case unsupportedPlatform
        case missingLocalRunner(String)
        case missingModelDownloader
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
            case .missingModelDownloader:
                return "Could not create the transcription model downloader."
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
        public var pythonPath: String?
        public var languageCode: String
        public var beamSize: Int
        public var modelName: String

        public init(
            pythonPath: String? = nil,
            languageCode: String = "en",
            beamSize: Int = 5,
            modelName: String = "Systran/faster-whisper-small"
        ) {
            self.pythonPath = pythonPath
            self.languageCode = languageCode
            self.beamSize = beamSize
            self.modelName = modelName
        }
    }

    private let configuration: Configuration
    private let modelDownloadService: LyricsModelDownloadService?
    #if os(macOS)
    private let runtimeService: LyricsRuntimeService?
    #endif
    private let canonicalLyricsService: CanonicalLyricsService
    private let fileManager: FileManager

    public init(
        configuration: Configuration = Configuration(),
        modelDownloadService: LyricsModelDownloadService? = try? LyricsModelDownloadService.defaultService(),
        canonicalLyricsService: CanonicalLyricsService = CanonicalLyricsService(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.modelDownloadService = modelDownloadService
        self.canonicalLyricsService = canonicalLyricsService
        #if os(macOS)
        self.runtimeService = try? LyricsRuntimeService.defaultService(preferredPythonPath: configuration.pythonPath)
        #endif
        self.fileManager = fileManager
    }

    public func transcribe(
        track: Track,
        sourceURL: URL,
        onModelDownloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> LyricsDocument {
        #if os(macOS)
        try Task.checkCancellation()
        guard let modelDownloadService else {
            throw TranscriptionError.missingModelDownloader
        }
        guard let runtimeService else {
            throw TranscriptionError.missingLocalRunner("managed runtime")
        }

        onModelDownloadProgress?(0)
        let pythonPath = try await runtimeService.pythonPath { _ in
            onModelDownloadProgress?(0.02)
        }
        try Task.checkCancellation()
        let modelURL = try await modelDownloadService.ensureModelAvailable { progress in
            onModelDownloadProgress?(0.05 + progress * 0.95)
        }
        try Task.checkCancellation()

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

        let outputURL = workingDirectory.appendingPathComponent("transcript.json")
        try await runTranscription(
            pythonPath: pythonPath,
            audioURL: sourceURL,
            outputURL: outputURL,
            modelURL: modelURL
        )
        var lines = try decodedLines(from: outputURL)
        let canonical: CanonicalLyricsService.Result?
        do {
            canonical = try await canonicalLyricsService.lyrics(for: track)
        } catch {
            try Task.checkCancellation()
            canonical = nil
        }
        try Task.checkCancellation()
        if let canonical {
            switch canonical {
            case .synced(let canonicalLines):
                lines = canonicalLines
            case .plain(let canonicalLines):
                lines = CanonicalLyricsService.align(canonicalLines, to: lines)
            case .instrumental:
                lines = [LyricsLine(
                    startTime: 0,
                    endTime: max(track.duration ?? 1, 1),
                    text: "Instrumental"
                )]
            }
        }
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
            transcriptionSpeed: 1,
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

    private func runTranscription(pythonPath: String, audioURL: URL, outputURL: URL, modelURL: URL) async throws {
        let script = """
import json
import sys
from faster_whisper import WhisperModel

model_path = sys.argv[1]
audio_path = sys.argv[2]
output_path = sys.argv[3]
language = sys.argv[4]
beam_size = int(sys.argv[5])

model = WhisperModel(model_path, device="cpu", compute_type="int8")
segments, info = model.transcribe(
    audio_path,
    language=language,
    beam_size=beam_size,
    word_timestamps=True,
    condition_on_previous_text=False,
)

rows = []
for segment in segments:
    words = list(segment.words or [])
    if not words:
        text = segment.text.strip()
        if text:
            rows.append({"start": float(segment.start), "end": float(segment.end), "text": text})
        continue

    phrase = []
    phrase_start = None
    previous_end = None
    for word in words:
        gap = 0 if previous_end is None else max(float(word.start) - previous_end, 0)
        if phrase and (gap > 0.8 or len(phrase) >= 9):
            rows.append({"start": phrase_start, "end": previous_end, "text": "".join(phrase).strip()})
            phrase = []
            phrase_start = None
        if phrase_start is None:
            phrase_start = float(word.start)
        phrase.append(word.word)
        previous_end = float(word.end)
        if word.word.rstrip().endswith((".", "!", "?")) and len(phrase) >= 4:
            rows.append({"start": phrase_start, "end": previous_end, "text": "".join(phrase).strip()})
            phrase = []
            phrase_start = None
    if phrase:
        rows.append({"start": phrase_start, "end": previous_end, "text": "".join(phrase).strip()})

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump({"segments": rows, "language": getattr(info, "language", language)}, handle, ensure_ascii=False)
"""

        let scriptURL = outputURL.deletingLastPathComponent().appendingPathComponent("transcribe.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptURL.path,
            modelURL.path,
            audioURL.path,
            outputURL.path,
            configuration.languageCode,
            String(configuration.beamSize)
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = nil
        environment["PYTHONPATH"] = nil
        process.environment = environment

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
        let logURL = fileManager.temporaryDirectory.appendingPathComponent("nightwing-lyrics-\(UUID().uuidString).log")
        guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
            throw TranscriptionError.transcriptionFailed("Could not create a transcription log.")
        }
        let output = try FileHandle(forWritingTo: logURL)
        process.standardOutput = output
        process.standardError = output
        defer {
            if process.isRunning {
                process.terminate()
            }
            try? output.close()
            try? fileManager.removeItem(at: logURL)
        }
        try process.run()

        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw CancellationError()
        }

        try output.synchronize()
        let data = (try? Data(contentsOf: logURL)) ?? Data()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    #endif
}
