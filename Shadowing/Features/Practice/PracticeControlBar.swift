import SwiftUI

/// v6 floating capsule at the bottom of the practice area: time, transport and Record.
struct PracticeControlBar: View {
    static let height: CGFloat = 60
    static let inset: CGFloat = 12

    @ObservedObject var viewModel: PracticeViewModel

    private var isRecording: Bool {
        viewModel.recordingPresentation.locksPracticeControls
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            layout(sideWidth: 110, spacing: 18)
            layout(sideWidth: 84, spacing: 12)
            layout(sideWidth: nil, spacing: 8)
        }
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .modifier(ControlBarBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls")
    }

    private func layout(sideWidth: CGFloat?, spacing: CGFloat) -> some View {
        HStack(spacing: 0) {
            timeText
                .frame(width: sideWidth, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: spacing) {
                PracticeLoopButton(viewModel: viewModel)
                PracticeTransportControls(viewModel: viewModel)
                PracticeRateMenu(viewModel: viewModel)
                PracticeVolumeButton(viewModel: viewModel)
            }
            .opacity(isRecording ? 0.35 : 1)
            .fixedSize()
            Spacer(minLength: 8)
            PracticeRecordControl(viewModel: viewModel)
                .frame(width: sideWidth, alignment: .trailing)
        }
    }

    private var timeText: some View {
        Text(
            verbatim: ClockText.paddedPosition(viewModel.playhead) + " / "
                + ClockText.paddedPosition(viewModel.project.duration)
        )
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("Playback position")
    }
}

extension EnvironmentValues {
    /// Draws floating chrome with a solid fill instead of Liquid Glass or a material.
    /// `cacheDisplay` cannot capture window-server glass, so pixel tests and snapshots set this.
    @Entry var prefersOpaqueChrome = false
}

/// Liquid Glass on macOS 26, bar material with a hairline and soft shadow on macOS 15.
private struct ControlBarBackground: ViewModifier {
    @Environment(\.prefersOpaqueChrome) private var prefersOpaqueChrome
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if prefersOpaqueChrome {
            content
                .background(opaqueFill, in: Capsule())
                .modifier(Hairline())
        } else if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.bar, in: Capsule())
                .modifier(Hairline())
        }
    }

    /// The design's bar colour: rgba(250,250,252,.92) light, rgba(38,38,41,.9) dark.
    private var opaqueFill: Color {
        colorScheme == .dark
            ? Color(red: 38 / 255, green: 38 / 255, blue: 41 / 255).opacity(0.9)
            : Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255).opacity(0.92)
    }

    private struct Hairline: ViewModifier {
        func body(content: Content) -> some View {
            content
                .overlay {
                    Capsule().strokeBorder(.separator, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
        }
    }
}

private struct PracticeTransportControls: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        Button {
            viewModel.jump(by: -5)
        } label: {
            Image(systemName: "gobackward.5")
                .font(.system(size: 18))
        }
        .buttonStyle(ControlBarIconStyle())
        .disabled(viewModel.controlsLocked)
        .accessibilityLabel("Back 5 seconds")
        .help("Back 5 seconds (←)")

        Button {
            viewModel.togglePlayback()
        } label: {
            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.primary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.controlsLocked)
        .accessibilityLabel(viewModel.isPlaying ? "Pause audio" : "Play audio")
        .help(viewModel.isPlaying ? "Pause audio (Space)" : "Play audio (Space)")

        Button {
            viewModel.jump(by: 5)
        } label: {
            Image(systemName: "goforward.5")
                .font(.system(size: 18))
        }
        .buttonStyle(ControlBarIconStyle())
        .disabled(viewModel.controlsLocked)
        .accessibilityLabel("Forward 5 seconds")
        .help("Forward 5 seconds (→)")
    }
}

private struct PracticeLoopButton: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        Button {
            viewModel.setLoopEnabled(!viewModel.loopEnabled)
        } label: {
            Image(systemName: "repeat")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(viewModel.loopEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(ControlBarIconStyle())
        .disabled(!viewModel.canToggleLoop)
        .accessibilityLabel(viewModel.loopEnabled ? "Disable loop" : "Enable loop")
        .accessibilityValue(viewModel.loopEnabled ? "On" : "Off")
        .accessibilityHint(
            viewModel.region == nil
                ? "Select a practice region before enabling loop."
                : "Repeats only the selected region."
        )
        .help(viewModel.loopEnabled ? "Disable loop (L)" : "Enable loop (L)")
    }
}

private struct PracticeRateMenu: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        Menu {
            Picker(
                "Playback speed",
                selection: Binding(
                    get: { viewModel.rate },
                    set: { viewModel.setRate($0) }
                )
            ) {
                ForEach(PracticeViewModel.supportedRates, id: \.self) { rate in
                    Text(verbatim: PracticeRateText.label(rate))
                        .tag(rate)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: PracticeRateText.label(viewModel.rate))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(viewModel.controlsLocked)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(PracticeRateText.label(viewModel.rate))
        .help("Playback speed")
    }
}

private struct PracticeVolumeButton: View {
    @ObservedObject var viewModel: PracticeViewModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: volumeImage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
        .buttonStyle(ControlBarIconStyle())
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Slider(
                value: Binding(
                    get: { viewModel.volume },
                    set: { viewModel.setVolume($0) }
                ),
                in: 0 ... 1
            )
            .frame(width: 160)
            .padding()
            .accessibilityLabel("Playback volume")
            .accessibilityValue("\(Int(viewModel.volume * 100)) percent")
        }
        .accessibilityLabel("Playback volume")
        .accessibilityValue("\(Int(viewModel.volume * 100)) percent")
        .help("Playback volume")
    }

    private var volumeImage: String {
        if viewModel.volume == 0 {
            return "speaker.slash"
        }
        return viewModel.volume < 0.5 ? "speaker.wave.1" : "speaker.wave.2"
    }
}

/// 40 pt ring with a red dot; while recording the dot becomes a square and a red timer appears.
struct PracticeRecordControl: View {
    @ObservedObject var viewModel: PracticeViewModel

    private var isRecording: Bool {
        viewModel.recordingPresentation.locksPracticeControls
    }

    var body: some View {
        HStack(spacing: 8) {
            if isRecording {
                Text(verbatim: ClockText.paddedPosition(viewModel.recordingElapsed))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.red)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            Button(action: toggle) {
                RecordGlyph(isRecording: isRecording)
            }
            .buttonStyle(.plain)
            .disabled(isRecording ? viewModel.recordingPresentation == .finalizing : viewModel.controlsLocked)
            .accessibilityLabel(isRecording ? "Stop Recording" : "Record")
            .accessibilityValue(isRecording ? Text("Recording") : Text(verbatim: ""))
            .accessibilityHint(isRecording ? Text(verbatim: "") : Text(Self.recordHint))
            .help(isRecording ? "Stop Recording (R)" : "Record (R)")
        }
        .onChange(of: isRecording) { _, recording in
            AccessibilityNotification.Announcement(
                recording ? String(localized: "Recording") : String(localized: "Recording stopped")
            ).post()
        }
    }

    private static let recordHint: LocalizedStringKey = """
    Starts recording from the current Original playhead until the audio ends, \
    or until you stop. With a take selected, recording replaces that take.
    """

    private func toggle() {
        if isRecording {
            viewModel.stopRecording()
        } else {
            viewModel.startRecording()
        }
    }
}

private struct RecordGlyph: View {
    let isRecording: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 2.5)
            if isRecording {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.red)
                    .frame(width: 14, height: 14)
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 28, height: 28)
            }
        }
        .frame(width: 40, height: 40)
        .contentShape(Circle())
        .animation(.snappy(duration: 0.18), value: isRecording)
    }
}

/// Borderless icon with a pressed state, sized for the capsule.
private struct ControlBarIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 24, minHeight: 28)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : (isEnabled ? 1 : 0.4))
    }
}
