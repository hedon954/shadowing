@testable import Shadowing
import SwiftUI
import XCTest

/// Subtitles inspector states from the `sub-*` mockups. Skipped unless snapshots are requested.
@MainActor
final class SubtitlesSnapshotTests: XCTestCase {
    func testNoSubtitles() async throws {
        try await renderPractice(name: "sub-empty") { _ in }
    }

    func testTimedSubtitlesHighlightTheCurrentSentence() async throws {
        try await renderPractice(name: "sub-timed") { practice in
            SnapshotFixtures.showTimedSubtitles(in: practice)
        }
    }

    func testAligningText() async throws {
        try await renderPractice(name: "sub-aligning") { practice in
            Self.showText(in: practice)
            practice.subtitles.display = .working(
                SubtitleWork(phase: .aligning, fraction: 0.42),
                text: SnapshotFixtures.sampleScript
            )
        }
    }

    func testDownloadingSpeechModel() async throws {
        try await renderPractice(name: "sub-model") { practice in
            Self.showText(in: practice)
            practice.subtitles.display = .working(
                SubtitleWork(phase: .downloadingModel, fraction: 0.18),
                text: SnapshotFixtures.sampleScript
            )
        }
    }

    func testAlignmentFailed() async throws {
        try await renderPractice(name: "sub-fail") { practice in
            Self.showText(in: practice)
            practice.subtitles.display = .plainText(SnapshotFixtures.sampleScript, notice: .alignmentFailed)
        }
    }

    func testGeneratingFromAudio() async throws {
        try await renderPractice(name: "sub-gen") { practice in
            practice.subtitles.sources = [
                SubtitleSourceOption(kind: .fromAudio, name: String(localized: "From audio"), isReady: false)
            ]
            practice.subtitles.activeSource = .fromAudio
            practice.subtitles.isGenerating = true
            let heard = SnapshotFixtures.sampleScript.split(separator: " ").prefix(40).joined(separator: " ")
            practice.subtitles.display = .working(SubtitleWork(phase: .recognizing, fraction: 0.42), text: heard)
        }
    }

    func testGenerationFailed() async throws {
        try await renderPractice(name: "sub-gen-fail") { practice in
            practice.subtitles.display = .empty
            practice.subtitles.generationError = SpeechRecognitionError.noSpeech.localizedDescription
        }
    }

    /// Hedon's window size with a long file name: the inspector text must not be clipped.
    func testLongSourceNameInNarrowWindow() async throws {
        try await renderPractice(name: "sub-timed-narrow", size: CGSize(width: 1024, height: 590)) { practice in
            SnapshotFixtures.showLongTimedSubtitles(in: practice)
        }
    }

    static func showText(in practice: PracticeViewModel) {
        practice.subtitles.sources = [SubtitleSourceOption(kind: .alignedText, name: "vulnerability.txt")]
        practice.subtitles.activeSource = .alignedText
    }

    private func renderPractice(
        name: String,
        size: CGSize = SnapshotSupport.windowSize,
        configure: @escaping @MainActor (PracticeViewModel) -> Void
    ) async throws {
        _ = try SnapshotSupport.outputDirectory()
        let library = try await SnapshotFixtures.library()
        let navigation = try SnapshotFixtures.navigation(testCase: self, library: library, openFirst: true)
        try await SnapshotSupport.render(ContentView(navigation: navigation), name: name, size: size) {
            guard let practice = await PracticeSnapshotTests.waitForPractice(navigation) else {
                return
            }
            if let newest = practice.takes.first {
                practice.selectTake(newest)
            }
            practice.playhead = 192
            configure(practice)
        }
    }
}
