@testable import Shadowing
import XCTest

final class SpeakerLineTests: XCTestCase {
    func testSplitsAShortSpeakerLabel() {
        let line = SpeakerLine.split("B: There is a bus at nine.")
        XCTAssertEqual(line.speaker, "B")
        XCTAssertEqual(line.text, "There is a bus at nine.")
        XCTAssertEqual(SpeakerLine.split("小王：你好").speaker, "小王")
    }

    func testKeepsColonsThatAreNotLabels() {
        XCTAssertNil(SpeakerLine.split("The meeting is at the usual place: room four.").speaker)
        XCTAssertNil(SpeakerLine.split("No colon here").speaker)
        XCTAssertNil(SpeakerLine.split("A:").speaker)
    }

    func testSubtitlePreferencesDefaultToHidden() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SpeakerLineTests-\(UUID().uuidString)"))
        XCTAssertFalse(defaults.bool(forKey: SubtitlePreferences.captionKey))
        XCTAssertFalse(defaults.bool(forKey: SubtitlePreferences.transcriptKey))
        XCTAssertNotEqual(SubtitlePreferences.captionKey, SubtitlePreferences.transcriptKey)
    }
}
