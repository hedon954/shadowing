import Foundation

/// Clock-style durations shared by the sidebar, toolbar and lists ("4:12", "1:02:05").
enum ClockText {
    static func duration(_ time: TimeInterval) -> String {
        let totalSeconds = time.isFinite ? max(Int(time.rounded()), 0) : 0
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// Zero-padded minutes for the playback position and recording timer ("03:12", "00:42").
    static func paddedPosition(_ time: TimeInterval) -> String {
        let totalSeconds = time.isFinite ? max(Int(time.rounded(.down)), 0) : 0
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
