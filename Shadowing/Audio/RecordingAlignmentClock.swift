@preconcurrency import AVFoundation
import Foundation

/// Notes when the first microphone buffer arrived and when the original really started, so the
/// take can be placed under the original. Written from the audio thread, read on the engine actor.
final class RecordingAlignmentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var firstInputHostTime: UInt64?
    private var playerStartHostTime: UInt64?

    func noteInput(_ when: AVAudioTime) {
        guard when.isHostTimeValid else {
            return
        }
        lock.withLock {
            if firstInputHostTime == nil {
                firstInputHostTime = when.hostTime
            }
        }
    }

    func notePlayerStart(hostTime: UInt64) {
        lock.withLock {
            playerStartHostTime = hostTime
        }
    }

    /// Nil when either side is unknown (for example recording without playing the original).
    func offset(outputLatency: TimeInterval, inputLatency: TimeInterval) -> TimeInterval? {
        let times = lock.withLock { (firstInputHostTime, playerStartHostTime) }
        guard let input = times.0, let player = times.1 else {
            return nil
        }
        return RecordingAlignment.measuredOffset(
            micFirstBufferSeconds: AVAudioTime.seconds(forHostTime: input),
            playerStartSeconds: AVAudioTime.seconds(forHostTime: player),
            outputLatency: outputLatency,
            inputLatency: inputLatency
        )
    }
}
