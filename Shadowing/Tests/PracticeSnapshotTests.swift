@testable import Shadowing
import SwiftUI
import XCTest

/// Practice and recording screens from the example library. Skipped unless snapshots are requested.
@MainActor
final class PracticeSnapshotTests: XCTestCase {
    func testPracticeWithSelectedTake() async throws {
        _ = try SnapshotSupport.outputDirectory()
        let library = try await SnapshotFixtures.library()
        let navigation = try SnapshotFixtures.navigation(testCase: self, library: library, openFirst: true)
        try await SnapshotSupport.render(ContentView(navigation: navigation), name: "practice") {
            guard let practice = await Self.waitForPractice(navigation) else {
                return
            }
            if let newest = practice.takes.first {
                practice.selectTake(newest)
            }
            practice.scriptText = SnapshotFixtures.sampleScript
            practice.project.scriptDisplayName = "vulnerability.txt"
            practice.playhead = 192
        }
    }

    func testRecordingNewTake() async throws {
        _ = try SnapshotSupport.outputDirectory()
        let library = try await SnapshotFixtures.library()
        let navigation = try SnapshotFixtures.navigation(testCase: self, library: library, openFirst: true)
        try await SnapshotSupport.render(ContentView(navigation: navigation), name: "recording") {
            guard let practice = await Self.waitForPractice(navigation) else {
                return
            }
            practice.clearTakeSelection()
            practice.scriptText = SnapshotFixtures.sampleScript
            practice.project.scriptDisplayName = "vulnerability.txt"
            Self.showRecording(practice, elapsed: 42)
        }
    }

    static func waitForPractice(_ navigation: AppNavigationModel) async -> PracticeViewModel? {
        for _ in 0 ..< 40 {
            if let practice = navigation.activePractice, !practice.takes.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
                return practice
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Practice screen did not open")
        return nil
    }

    /// Puts the screen into the recording state with a synthetic live waveform; no microphone.
    static func showRecording(_ practice: PracticeViewModel, elapsed: TimeInterval) {
        let peaks = SnapshotFixtures.waveform(duration: elapsed, seed: 11).peaks
        practice.liveRecordingEnvelope = peaks.enumerated().map { index, peak in
            TimedWaveformEnvelopePoint(
                time: elapsed * Double(index) / Double(max(peaks.count - 1, 1)),
                envelope: WaveformEnvelopePoint(minimum: -peak, maximum: peak)
            )
        }
        practice.playhead = elapsed
        practice.interactionPhase = .recording
        practice.recordingPresentation = .recording(elapsed: elapsed)
    }
}
