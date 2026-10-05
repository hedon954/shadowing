import Foundation
import XCTest

/// The real `PracticeAudioEngine` can't run under XCTest, so these tests read its sources to check
/// the split the 2026-10-05 hang fix depends on: the playback engine never gets a microphone
/// input, and recording uses its own input-only engine that never gets an output.
final class MicrophoneInputWiringTests: XCTestCase {
    private let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testOnlyTheRecorderReachesAnInputNode() throws {
        XCTAssertEqual(try occurrences(of: "inputNode"), ["MicrophoneRecorder.swift": 5])
        for file in try playbackEngineSources() {
            XCTAssertFalse(try source(file).contains("inputNode"), "\(file) must never create an input")
        }
    }

    func testRecordingEngineNeverGetsAnOutput() throws {
        let recorder = try source("Audio/MicrophoneRecorder.swift")
        // An output makes macOS switch the engine to an aggregate input/output device.
        XCTAssertFalse(recorder.contains("mainMixerNode"))
        XCTAssertFalse(recorder.contains("outputNode"))
        XCTAssertFalse(recorder.contains("connect("))
        XCTAssertFalse(recorder.contains("attach("))
    }

    func testPlaybackAndRecordingUseSeparateEngines() throws {
        XCTAssertEqual(
            try occurrences(of: "AVAudioEngine()"),
            ["PracticeAudioEngine.swift": 1, "MicrophoneRecorder.swift": 1]
        )
        let engine = try source("Audio/PracticeAudioEngine.swift")
        XCTAssertTrue(engine.contains("makeRecorder: MicrophoneRecorder.init"))
        XCTAssertTrue(engine.contains("let engine = AVAudioEngine()"), "the playback engine is never replaced")
    }

    func testOpeningAProjectNeverAsksForTheMicrophone() throws {
        let commands = try source("Audio/PracticeAudioEngine+Commands.swift")
        let load = try body(of: "func load(", in: commands)
        XCTAssertTrue(load.contains("engine.prepare()"))
        XCTAssertFalse(commands.contains("inputGate"))
    }

    func testOnlyStartRecordingCreatesARecorder() throws {
        XCTAssertEqual(
            try occurrences(of: "recorderIfAuthorized()"),
            ["MicrophoneInputGate.swift": 1, "PracticeAudioEngine+Recording.swift": 1]
        )
        let recording = try source("Audio/PracticeAudioEngine+Recording.swift")
        XCTAssertTrue(try body(of: "func startRecording(", in: recording).contains("inputGate.recorderIfAuthorized()"))
    }

    func testEveryRecordingEndStopsTheInputAndNeverWaitsForever() throws {
        let recording = try source("Audio/PracticeAudioEngine+Recording.swift")
        for function in ["func abortRecording(", "func finishRecording("] {
            let body = try body(of: function, in: recording)
            XCTAssertTrue(body.contains("context.take.stopInput()"), "\(function) must stop the take's input")
            XCTAssertTrue(body.contains("finishKeepingAudio(timeout:"), "\(function) needs a close timeout")
            XCTAssertFalse(body.contains("pipeline.finish()"), "\(function) must not wait without a timeout")
        }
        let start = try body(of: "func startRecording(", in: recording)
        XCTAssertTrue(start.contains("startFirstAudioWatchdog"))
        XCTAssertTrue(start.contains("onConfigurationChange:"))
    }

    // MARK: - Helpers

    private func playbackEngineSources() throws -> [String] {
        let audio = sourceRoot.appendingPathComponent("Audio", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: audio.path)
            .filter { $0.hasPrefix("PracticeAudioEngine") && $0.hasSuffix(".swift") }
            .map { "Audio/\($0)" }
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Counts per app source file (tests excluded).
    private func occurrences(of text: String) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for folder in ["App", "Audio", "Domain", "Features", "Services"] {
            let directory = sourceRoot.appendingPathComponent(folder, isDirectory: true)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let count = try String(contentsOf: file, encoding: .utf8).components(separatedBy: text).count - 1
                if count > 0 {
                    counts[file.lastPathComponent, default: 0] += count
                }
            }
        }
        return counts
    }

    /// The text from `signature` up to the next member declaration at the same indentation.
    private func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "Missing \(signature)")
        let rest = source[start.upperBound...]
        let end = rest.range(
            of: #"\n    (private |nonisolated |static )*(func|var|let|init) |\n}"#,
            options: .regularExpression
        )
        return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
    }
}
