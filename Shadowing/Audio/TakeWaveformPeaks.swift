@preconcurrency import AVFoundation
import Foundation

enum TakeWaveformPeaks {
    /// Builds a multi-resolution waveform when no shared cache service is injected.
    static func load(
        from url: URL
    ) async throws -> WaveformPresentation {
        let waveform = try await WaveformPeakGenerator().generate(
            from: url
        )
        return WaveformPresentation(
            duration: waveform.duration,
            sampleRate: waveform.sampleRate,
            levels: waveform.levels,
            warning: nil
        )
    }
}
