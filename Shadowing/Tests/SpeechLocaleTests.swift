import Foundation
@testable import Shadowing
import Speech
import XCTest

/// Subtitles are English whatever the UI language. Run with `-testLanguage zh-Hans` to check
/// this under the Chinese UI (done alongside the zh-Hans snapshot run).
final class SpeechLocaleTests: XCTestCase {
    func testRecognitionUsesEnglishEvenWhenTheAppIsInChinese() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer needs macOS 26")
        }
        XCTAssertEqual(SpeechAnalyzerRecognizer.locale.identifier, "en-US")
        let transcriber = SpeechAnalyzerRecognizer.makeTranscriber()
        XCTAssertEqual(transcriber.selectedLocales.map { $0.identifier(.bcp47) }, ["en-US"])

        let uiLanguage = Bundle.main.preferredLocalizations.first ?? ""
        if uiLanguage.hasPrefix("zh") {
            XCTAssertEqual(Locale.current.language.languageCode, .chinese)
            XCTAssertNotEqual(
                Locale.current.language.languageCode,
                SpeechAnalyzerRecognizer.locale.language.languageCode
            )
        }
    }

    func testChineseLocaleIsNotUsedForRecognition() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer needs macOS 26")
        }
        let chinese = Locale(identifier: "zh-Hans-CN")
        XCTAssertNotEqual(SpeechAnalyzerRecognizer.locale.language, chinese.language)
        XCTAssertEqual(SpeechAnalyzerRecognizer.locale.language.languageCode, .english)
        XCTAssertEqual(SpeechAnalyzerRecognizer.locale.region, .unitedStates)
    }
}
