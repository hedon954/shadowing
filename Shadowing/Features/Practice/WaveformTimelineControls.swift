import SwiftUI

/// Pan, zoom, "Full" and "Selection" buttons shown while the waveform is zoomed in.
struct WaveformTimelineControls: View {
    let canFitRegion: Bool
    let isEnabled: Bool
    let onZoom: (Double) -> Void
    let onPan: (Double) -> Void
    let onShowFull: () -> Void
    let onFitRegion: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(
                action: { onPan(-0.25) },
                label: { Image(systemName: "chevron.left") }
            )
            Button(
                action: { onZoom(0.5) },
                label: { Image(systemName: "minus.magnifyingglass") }
            )
            Button(
                action: { onZoom(2) },
                label: { Image(systemName: "plus.magnifyingglass") }
            )
            Button(
                action: { onPan(0.25) },
                label: { Image(systemName: "chevron.right") }
            )
            Divider().frame(height: 16)
            Button("Full", action: onShowFull)
            Button("Selection", action: onFitRegion)
                .disabled(!canFitRegion)
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
    }
}
