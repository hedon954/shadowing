import Foundation

/// The one clock-style time format for the whole app: elapsed time, durations, ranges and
/// waveform labels ("0:48", "2:09", "1:02:03"). Minutes have no leading zero.
enum ClockText {
    /// Whole seconds are floored everywhere, so a 129.9 s track reads 2:09 in the title,
    /// sidebar and playback bar alike, and the playhead at the very end reads the same.
    /// A 1 ms tolerance keeps float noise (2.9999999 s from tick math) on 0:03.
    static func format(_ time: TimeInterval) -> String {
        let totalSeconds = time.isFinite ? max(Int((time + 0.001).rounded(.down)), 0) : 0
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
