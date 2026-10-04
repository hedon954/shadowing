import Foundation
@testable import Shadowing
import XCTest

/// Checks the compiled String Catalog: Chinese labels, plural forms and locale-aware dates.
final class LocalizationTests: XCTestCase {
    private func bundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle(for: AppNavigationModel.self).path(forResource: language, ofType: "lproj"),
            "\(language).lproj is missing from the app"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    private func format(_ key: String, _ count: Int, language: String) throws -> String {
        let template = try bundle(language).localizedString(forKey: key, value: nil, table: nil)
        return String(format: template, locale: Locale(identifier: language), count)
    }

    func testChineseLabelsFollowTheDesignTable() throws {
        let zh = try bundle("zh-Hans")
        let expected = [
            "Library": "练习材料",
            "No practice files yet": "还没有练习材料",
            "Open MP3…": "打开 MP3…",
            "Original": "原音",
            "Takes": "跟读",
            "Record": "录音",
            "Recording": "正在录音",
            "Subtitles": "字幕",
            "No subtitles yet": "还没有字幕",
            "Input Device": "输入设备",
            "Input Level": "输入电平",
            "Drop an MP3 anywhere in this window to start": "把 MP3 拖进窗口任意位置就能开始"
        ]
        for (key, value) in expected {
            XCTAssertEqual(zh.localizedString(forKey: key, value: nil, table: nil), value, key)
        }
    }

    func testTakeCountsUsePluralVariations() throws {
        XCTAssertEqual(try format("%lld takes", 1, language: "en"), "1 take")
        XCTAssertEqual(try format("%lld takes", 3, language: "en"), "3 takes")
        XCTAssertEqual(try format("%lld takes", 1, language: "zh-Hans"), "1 次跟读")
        XCTAssertEqual(try format("%lld takes", 3, language: "zh-Hans"), "3 次跟读")
        XCTAssertEqual(try format("Take %lld", 4, language: "zh-Hans"), "第 4 遍")
        XCTAssertEqual(try format("Recording · Take %lld", 4, language: "zh-Hans"), "正在录音 · 第 4 遍")
    }

    func testDatesFollowTheLanguage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 20)))
        var day = Date.FormatStyle.practiceDay
        day.timeZone = calendar.timeZone
        XCTAssertEqual(day.locale(Locale(identifier: "en_US")).format(date), "Oct 4")
        XCTAssertEqual(day.locale(Locale(identifier: "zh-Hans_CN")).format(date), "10月4日")
    }
}
