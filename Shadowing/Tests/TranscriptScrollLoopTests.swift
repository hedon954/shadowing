import Combine
import Foundation
@testable import Shadowing
import XCTest

/// Wheel-scrolling the transcript must stay one-directional: the user's scroll is noted for
/// the 3 s follow pause, but it never redraws the practice view or asks for a reveal, so it
/// cannot feed back into the transcript's layout.
@MainActor
final class TranscriptScrollLoopTests: XCTestCase {
    func testUserScrollNeverPublishesOrRequestsReveal() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        let token = model.revealToken
        let changes = ChangeCounter(model.objectWillChange)
        let start = Date(timeIntervalSince1970: 1000)

        for tick in 0 ..< 15 {
            model.noteTranscriptUserScroll(at: start.addingTimeInterval(Double(tick) * 0.05))
        }

        XCTAssertEqual(changes.count, 0, "a user scroll must not redraw the practice view")
        XCTAssertEqual(model.revealToken, token, "a user scroll never asks the transcript to scroll")
        XCTAssertEqual(model.jumpReveal.token, token)
        XCTAssertFalse(model.transcriptAutoFollows(at: start.addingTimeInterval(1)))
        XCTAssertTrue(model.transcriptAutoFollows(at: start.addingTimeInterval(0.7 + 3)))
    }

    func testActiveJumpPublishesTheRevealTokenOnce() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        let token = model.revealToken
        var published: [Int] = []
        let subscription = model.$revealToken.dropFirst().sink { published.append($0) }

        model.noteTranscriptUserScroll(at: Date())
        model.revealPlayhead()

        XCTAssertEqual(published, [token + 1])
        XCTAssertEqual(model.revealToken, model.jumpReveal.token)
        XCTAssertTrue(model.transcriptAutoFollows(at: Date()), "an active jump ends the pause")
        subscription.cancel()
    }
}

/// Counts emissions of a publisher while alive.
private final class ChangeCounter {
    private(set) var count = 0
    private var subscription: AnyCancellable?

    init(_ publisher: ObservableObjectPublisher) {
        subscription = publisher.sink { [weak self] _ in self?.count += 1 }
    }
}
