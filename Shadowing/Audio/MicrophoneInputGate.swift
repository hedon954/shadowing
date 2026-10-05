import Foundation

/// Owns `PracticeAudioEngine`'s `AVAudioEngine` and is the only way to reach its microphone input.
///
/// Creating the engine's input makes macOS check microphone access, and once the input exists,
/// every start of that engine (playback included) keeps the microphone in use: the orange
/// indicator shows, and an app without a stable signature is asked again. So:
/// - the input is created only for recording, and only when access is already granted (reading
///   the status never prompts; `PracticeViewModel` asks when the user presses R);
/// - opening a project or playing never asks for the input;
/// - when a recording ends, the engine that had an input is retired and playback continues on a
///   fresh engine that never had one.
///
/// The status is read on every call, so access granted in System Settings works without a
/// restart. Generic so tests can use counting fakes instead of a real audio engine.
final class MicrophoneInputGate<Engine, Input> {
    typealias StatusProvider = @Sendable () -> MicrophonePermissionState

    private let status: StatusProvider
    private let makeEngine: () -> Engine
    private let makeInput: (Engine) -> Input
    /// The engine for playback (and, once an input is created, the current recording).
    private(set) var engine: Engine
    /// The current engine's input, if one was created (for removing taps and reading latency).
    private(set) var existingInput: Input?
    private(set) var inputCreationCount = 0
    private(set) var engineReplacementCount = 0

    init(
        engine: Engine,
        status: @escaping StatusProvider,
        makeEngine: @escaping () -> Engine,
        makeInput: @escaping (Engine) -> Input
    ) {
        self.engine = engine
        self.status = status
        self.makeEngine = makeEngine
        self.makeInput = makeInput
    }

    /// The input for recording when microphone access is granted; otherwise `nil`, without
    /// creating anything.
    func inputIfAuthorized() -> Input? {
        guard status() == .authorized else {
            return nil
        }
        if let existingInput {
            return existingInput
        }
        let input = makeInput(engine)
        existingInput = input
        inputCreationCount += 1
        return input
    }

    /// Call when a recording ends (finished, aborted or failed to start). If the current engine
    /// has an input, it is replaced by a fresh engine without one and returned so its nodes can
    /// be moved over; `nil` when the engine never had an input.
    func replaceEngineIfItHasInput() -> Engine? {
        guard existingInput != nil else {
            return nil
        }
        let retired = engine
        engine = makeEngine()
        existingInput = nil
        engineReplacementCount += 1
        return retired
    }
}
