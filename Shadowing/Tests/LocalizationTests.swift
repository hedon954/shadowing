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
            "Transcript": "全文字幕",
            "No Takes Yet": "还没有跟读",
            "Press R to record your first take": "按 R 录第一遍",
            "No subtitles yet": "还没有字幕",
            "Input Device": "输入设备",
            "Input Level": "输入电平",
            "Drop an MP3 anywhere in this window to start": "把 MP3 拖进窗口任意位置就能开始",
            "Subtitle Source": "字幕来源",
            "Subtitle file": "字幕文件",
            "Aligned text": "文本对齐",
            "Add Subtitle File…": "添加字幕文件…",
            "Aligning text…": "正在对齐文本…",
            "Downloading English speech model (one time)…": "正在下载英语语音模型（只需一次）…",
            "Runs on this Mac. Nothing is uploaded.": "在本机完成，不上传。",
            "Can't align. Showing plain text.": "无法对齐，先显示普通文本",
            "Click a sentence to jump there": "点一句即可跳到那里",
            "Pick another source from the menu above": "可以在上方菜单换一个来源",
            "From audio": "从音频识别",
            "Not generated": "未生成",
            "Generate Subtitles from Audio": "从音频生成字幕",
            "Export .srt…": "导出 .srt…",
            "Recognizing speech…": "正在从音频识别文字…",
            "Runs on this Mac. Nothing is uploaded. Text appears below as it's recognized.":
                "在本机完成，不上传。识别出的文字会陆续出现在下面。",
            "Highlighting starts when recognition finishes": "识别完成后自动开始高亮",
            "Requires macOS 26": "需要 macOS 26",
            "Can't generate subtitles.": "无法生成字幕"
        ]
        for (key, value) in expected {
            XCTAssertEqual(zh.localizedString(forKey: key, value: nil, table: nil), value, key)
        }
    }

    func testSpeechRecognitionPromptIsLocalized() throws {
        let app = Bundle(for: AppNavigationModel.self)
        XCTAssertEqual(
            app.infoDictionary?["NSSpeechRecognitionUsageDescription"] as? String,
            "Shadowing recognizes speech on this Mac to time your subtitles. Audio never leaves your Mac."
        )
        XCTAssertEqual(
            try bundle("zh-Hans").localizedString(
                forKey: "NSSpeechRecognitionUsageDescription",
                value: nil,
                table: "InfoPlist"
            ),
            "Shadowing 会在本机识别语音，为字幕配上时间。音频不会离开你的 Mac。"
        )
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
