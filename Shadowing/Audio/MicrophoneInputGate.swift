import Foundation

/// The only way to get a microphone recorder for a take.
///
/// Recording runs on its own input-only `AVAudioEngine`, never on the playback engine: creating
/// an input on an engine that is already playing makes macOS switch that engine to an aggregate
/// input/output device, which stops its I/O, so the tap never receives audio and the take hangs
/// (2026-10-05). So:
/// - a recorder is created only for recording, and only when access is already granted (reading
///   the status never prompts; `PracticeViewModel` asks when the user presses R);
/// - opening a project or playing never creates one, so the playback engine never has an input;
/// - every take gets a fresh recorder, which is thrown away when the take ends.
///
/// The status is read on every call, so access granted in System Settings works without a
/// restart. Generic so tests can use counting fakes instead of a real audio engine.
final class MicrophoneInputGate<Recorder> {
    typealias StatusProvider = @Sendable () -> MicrophonePermissionState

    private let status: StatusProvider
    private let makeRecorder: () -> Recorder
    private(set) var recorderCreationCount = 0

    init(status: @escaping StatusProvider, makeRecorder: @escaping () -> Recorder) {
        self.status = status
        self.makeRecorder = makeRecorder
    }

    /// A fresh recorder when microphone access is granted; otherwise `nil`, without creating
    /// anything. Never reused: the caller throws it away when the take ends.
    func recorderIfAuthorized() -> Recorder? {
        guard status() == .authorized else {
            return nil
        }
        recorderCreationCount += 1
        return makeRecorder()
    }
}
