@testable import Shadowing
import SwiftUI
import XCTest

/// The v8 compare, recording and subtitles-on screens, sized like the mockups (1180×720).
/// Skipped unless snapshots are requested. Preferences go to a throwaway defaults suite.
@MainActor
final class V8SnapshotTests: XCTestCase {
    static let entries: [SnapshotFixtures.Entry] = [
        .init(name: "Second hand ecommerce idle asset liquidity conversation", duration: 130, takeCount: 3),
        .init(name: "Non-standardization in second hand trading", duration: 132, takeCount: 0),
        .init(name: "TED: The power of vulnerability", duration: 1249, takeCount: 5),
        .init(name: "BBC 6 Minute English: Why we procrastinate", duration: 372, takeCount: 1)
    ]

    /// Pause cuts every 6–17 s, with one sentence at 0:48–1:05 like the mockup.
    static let chunks: [SentenceChunk] = {
        let bounds: [(TimeInterval, TimeInterval)] = [
            (0.4, 7.2), (7.9, 15.1), (15.8, 24.6), (25.3, 31.0), (31.6, 40.2), (40.9, 47.4),
            (48, 65), (65.7, 74.3), (75.0, 83.8), (84.5, 92.0), (92.6, 101.9), (102.5, 110.7),
            (111.4, 119.0), (119.6, 129.5)
        ]
        return bounds.map { SentenceChunk(start: $0.0, end: $0.1) }
    }()

    static let caption = SubtitleCue(
        start: 48,
        end: 65,
        text: "B: There is a possible trading zone, but the deal will not happen automatically."
    )

    func testCompare() async throws {
        try await render(name: "v8-compare") { practice in
            Self.selectNewestTake(practice)
        }
    }

    func testRecording() async throws {
        try await render(name: "v8-rec") { practice in
            practice.clearTakeSelection()
            practice.recordingWindow = try? PracticeRegion.takeAlignment(start: 0, end: 130, sourceDuration: 130)
            PracticeSnapshotTests.showRecording(practice, elapsed: 57)
        }
    }

    func testSubtitlesOn() async throws {
        try await render(name: "v8-captions", captionVisible: true) { practice in
            Self.selectNewestTake(practice)
            practice.subtitles.sources = [SubtitleSourceOption(kind: .subtitleFile, name: "conversation.srt")]
            practice.subtitles.activeSource = .subtitleFile
            practice.subtitles.display = .timed(SubtitleTranscript(cues: [Self.caption]))
        }
    }

    private static func selectNewestTake(_ practice: PracticeViewModel) {
        if let newest = practice.takes.first {
            practice.selectTake(newest)
        }
    }

    private func render(
        name: String,
        captionVisible: Bool = false,
        configure: @escaping @MainActor (PracticeViewModel) -> Void
    ) async throws {
        _ = try SnapshotSupport.outputDirectory()
        let store = try XCTUnwrap(UserDefaults(suiteName: "V8SnapshotTests-\(UUID().uuidString)"))
        store.set(captionVisible, forKey: SubtitlePreferences.captionKey)
        store.set(false, forKey: SubtitlePreferences.transcriptKey)
        let library = try await SnapshotFixtures.library(
            entries: Self.entries,
            takeLengths: [131, 125, 118],
            takeSpacing: 0
        )
        let navigation = try SnapshotFixtures.navigation(testCase: self, library: library, openFirst: true)
        let view = ContentView(navigation: navigation).defaultAppStorage(store)
        try await SnapshotSupport.render(view, name: name) {
            guard let practice = await PracticeSnapshotTests.waitForPractice(navigation) else {
                return
            }
            practice.sentenceChunks = Self.chunks
            practice.playhead = 57
            configure(practice)
        }
    }
}
