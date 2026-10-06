#if DEBUG
    /// Debug-only body-evaluation counters, read by tests to see which views redraw per tick.
    @MainActor
    enum RenderProbe {
        static var counts: [String: Int] = [:]

        static func note(_ name: String) {
            counts[name, default: 0] += 1
        }
    }
#endif
