import Foundation
@testable import Shadowing
import XCTest

/// Designer rule: a single click on the waveform only moves the playhead. Playing continues
/// from the new spot; paused stays paused. Also with a take selected (the click deselects it).
@MainActor
final class WaveformClickPlaybackTests: XCTestCase {
    /// What `OriginalWaveformSection` runs on a click.
    private func click(_ model: PracticeViewModel, at time: TimeInterval) {
        model.clearTakeSelection()
        model.seekTimeline(time)
    }

    private func playing(_ fixture: M9Fixture) async {
        let model = fixture.viewModel
        await M9TestSupport.waitUntil { model.revealToken > 0 }
        model.stopComparison()
        if !model.isPlaying {
            model.togglePlayback()
        }
        await M9TestSupport.waitUntil { model.isPlaying }
    }

    func testClickWhilePlayingKeepsPlayingFromTheNewSpot() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self, selectRegion: false)
        await playing(fixture)
        let before = await fixture.audio.commands.count

        click(fixture.viewModel, at: 21)
        await M9TestSupport.waitForCommand(.seek(21), audio: fixture.audio)

        XCTAssertTrue(fixture.viewModel.isPlaying)
        XCTAssertEqual(fixture.viewModel.playhead, 21, accuracy: 1e-9)
        let after = await fixture.audio.commands.dropFirst(before)
        XCTAssertFalse(after.contains(.pause), "a click never pauses: \(Array(after))")
    }

    func testClickWhilePlayingWithATakeSelectedKeepsPlaying() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        XCTAssertNotNil(fixture.viewModel.activeTake)
        await playing(fixture)
        let before = await fixture.audio.commands.count

        click(fixture.viewModel, at: 21)
        await M9TestSupport.waitForCommand(.seek(21), audio: fixture.audio)

        XCTAssertNil(fixture.viewModel.activeTake, "the click deselects the take")
        XCTAssertTrue(fixture.viewModel.isPlaying)
        let after = await fixture.audio.commands.dropFirst(before)
        XCTAssertFalse(after.contains(.pause), "a click never pauses: \(Array(after))")
    }

    func testClickWhilePausedStaysPaused() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self, selectRegion: false)
        let model = fixture.viewModel
        await M9TestSupport.waitUntil { model.revealToken > 0 }
        XCTAssertFalse(model.isPlaying)

        click(model, at: 12)
        await M9TestSupport.waitForCommand(.seek(12), audio: fixture.audio)

        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playhead, 12, accuracy: 1e-9)
        let commands = await fixture.audio.commands
        XCTAssertFalse(commands.contains {
            if case .playOriginal = $0 {
                true
            } else {
                false
            }
        })
    }
}
