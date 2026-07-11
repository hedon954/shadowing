import Foundation

struct CachedWaveformService: WaveformPreparing {
    private let generator: WaveformPeakGenerator
    private let cache: WaveformFileCache
    private let maximumPresentationPeaks: Int

    init(
        generator: WaveformPeakGenerator = WaveformPeakGenerator(),
        cache: WaveformFileCache,
        maximumPresentationPeaks: Int = 4096
    ) {
        self.generator = generator
        self.cache = cache
        self.maximumPresentationPeaks = maximumPresentationPeaks
    }

    func prepareWaveform(from url: URL) async throws -> WaveformPresentation {
        try Task.checkCancellation()
        let fingerprint = try SourceFingerprint.make(for: url)
        var warning: String?

        do {
            if let cached = try await cache.load(for: fingerprint) {
                return makePresentation(from: cached, warning: nil)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warning = "The waveform cache could not be read and was rebuilt."
        }

        let waveform = try await generator.generate(from: url)
        try Task.checkCancellation()
        do {
            try await cache.store(waveform)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warning = "The waveform is ready, but its cache could not be saved."
        }
        return makePresentation(from: waveform, warning: warning)
    }

    private func makePresentation(
        from waveform: WaveformData,
        warning: String?
    ) -> WaveformPresentation {
        let peaks = waveform.levels.max { first, second in
            first.framesPerPeak < second.framesPerPeak
        }?.peaks ?? []
        return WaveformPresentation(
            peaks: WaveformDownsampler.downsample(
                peaks,
                maximumCount: maximumPresentationPeaks
            ),
            warning: warning
        )
    }
}

enum WaveformDownsampler {
    static func downsample(_ peaks: [Float], maximumCount: Int) -> [Float] {
        guard maximumCount > 0, peaks.count > maximumCount else {
            return maximumCount > 0 ? peaks : []
        }

        return (0 ..< maximumCount).map { index in
            let start = index * peaks.count / maximumCount
            let end = max((index + 1) * peaks.count / maximumCount, start + 1)
            return peaks[start ..< min(end, peaks.count)].max() ?? 0
        }
    }
}
