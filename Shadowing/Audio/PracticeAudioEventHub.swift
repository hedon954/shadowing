import Foundation
import Synchronization

/// Fans engine events out to every subscriber: each `makeStream()` returns its own stream.
///
/// The engine used to hand every practice the same `AsyncStream`. Closing a practice cancels
/// its event loop, and cancelling a task that waits on an `AsyncStream` terminates that stream
/// for everyone, so after a project switch the new practice never received another playhead
/// event (time frozen until relaunch). Now a closing practice ends only its own stream.
final class PracticeAudioEventHub: Sendable {
    private struct State {
        var subscribers: [UInt64: AsyncStream<PracticeAudioEvent>.Continuation] = [:]
        var nextID: UInt64 = 0
        var isFinished = false
    }

    private let state = Mutex(State())
    private let bufferLimit: Int

    init(bufferLimit: Int = 256) {
        self.bufferLimit = bufferLimit
    }

    var subscriberCount: Int {
        state.withLock { $0.subscribers.count }
    }

    /// A new stream that receives every event yielded from now on.
    func makeStream() -> AsyncStream<PracticeAudioEvent> {
        let (stream, continuation) = AsyncStream<PracticeAudioEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferLimit)
        )
        let id: UInt64? = state.withLock { state in
            guard !state.isFinished else {
                return nil
            }
            let id = state.nextID
            state.nextID &+= 1
            state.subscribers[id] = continuation
            return id
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func yield(_ event: PracticeAudioEvent) {
        let subscribers = state.withLock { Array($0.subscribers) }
        for (id, continuation) in subscribers {
            if case .terminated = continuation.yield(event) {
                remove(id)
            }
        }
    }

    func finish() {
        let subscribers = state.withLock { state in
            state.isFinished = true
            let continuations = Array(state.subscribers.values)
            state.subscribers = [:]
            return continuations
        }
        for continuation in subscribers {
            continuation.finish()
        }
    }

    private func remove(_ id: UInt64) {
        state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
    }
}
