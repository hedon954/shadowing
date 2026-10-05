import Foundation
import XCTest

/// The real `PracticeAudioEngine` can't run under XCTest, so these tests read its sources to check
/// that it uses `MicrophoneInputGate` as the gate tests assume: the input is created only by
/// `startRecording`, and every way a recording ends moves playback to a fresh engine.
final class MicrophoneInputWiringTests: XCTestCase {
    private let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testOnlyTheGateReachesTheEngineInputNode() throws {
        XCTAssertEqual(try occurrences(of: "inputNode"), ["PracticeAudioEngine.swift": 1])
        XCTAssertEqual(try occurrences(of: "AVAudioEngine()"), ["PracticeAudioEngine.swift": 1])
    }

    func testOpeningAProjectNeverAsksForTheInput() throws {
        let commands = try source("Audio/PracticeAudioEngine+Commands.swift")
        let load = try body(of: "func load(", in: commands)
        XCTAssertTrue(load.contains("engine.prepare()"))
        XCTAssertFalse(commands.contains("inputGate"))
        XCTAssertFalse(load.contains("inputNode"))
    }

    func testOnlyStartRecordingCreatesTheInput() throws {
        XCTAssertEqual(
            try occurrences(of: "inputIfAuthorized()"),
            ["MicrophoneInputGate.swift": 1, "PracticeAudioEngine+Recording.swift": 1]
        )
        let recording = try source("Audio/PracticeAudioEngine+Recording.swift")
        XCTAssertTrue(try body(of: "func startRecording(", in: recording).contains("inputGate.inputIfAuthorized()"))
    }

    func testEveryRecordingEndMovesPlaybackToAnEngineWithoutInput() throws {
        let recording = try source("Audio/PracticeAudioEngine+Recording.swift")
        for function in ["func startRecording(", "func abortRecording(", "func finishRecording("] {
            XCTAssertTrue(
                try body(of: function, in: recording).contains("replaceEngineAfterRecording()"),
                "\(function) must replace the engine that had an input"
            )
        }
        let engine = try source("Audio/PracticeAudioEngine.swift")
        let replacement = try body(of: "func replaceEngineAfterRecording(", in: engine)
        XCTAssertTrue(replacement.contains("inputGate.replaceEngineIfItHasInput()"))
    }

    // MARK: - Helpers

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
