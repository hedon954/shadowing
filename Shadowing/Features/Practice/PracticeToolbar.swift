import SwiftUI

/// Title, transport, record and inspector controls in the window's unified toolbar.
struct PracticeToolbar: ToolbarContent {
    let viewModel: PracticeViewModel
    @Binding var isInspectorPresented: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            PracticeToolbarTitle(viewModel: viewModel)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            PracticeTransportControls(viewModel: viewModel)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            PracticeLoopRateVolumeControls(viewModel: viewModel)
        }
        ToolbarItem(placement: .primaryAction) {
            PracticeRecordButton(viewModel: viewModel)
        }
        ToolbarItem(placement: .primaryAction) {
            InspectorToggleButton(isPresented: $isInspectorPresented)
        }
    }
}

/// The same toolbar, all disabled, while no practice file is open.
struct PlaceholderPracticeToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Group {
                Button("Back 5 seconds", systemImage: "gobackward.5") {}
                Button("Play audio", systemImage: "play.fill") {}
                Button("Forward 5 seconds", systemImage: "goforward.5") {}
            }
            .disabled(true)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Group {
                Button("Enable loop", systemImage: "repeat") {}
                Button(PracticeRateText.label(1)) {}
                Button("Playback volume", systemImage: "speaker.wave.2") {}
            }
            .disabled(true)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {} label: {
                Label("Record", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(true)
        }
    }
}

private struct PracticeToolbarTitle: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: DisplayName.cleaned(viewModel.project.sourceDisplayName))
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .truncationMode(.tail)
            subtitle
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .help(viewModel.project.sourceDisplayName)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch viewModel.headerStatus {
        case let .takes(count, _):
            Text(verbatim: PracticeTitleText.summary(duration: viewModel.project.duration, takeCount: count))
                .foregroundStyle(.secondary)
        case .checkingMicrophone:
            Text("Checking microphone…")
                .foregroundStyle(.secondary)
        case let .countingDown(_, remainingSeconds):
            Text("Recording starts in \(remainingSeconds)")
                .foregroundStyle(.red)
        case let .recording(takeNumber):
            (Text(verbatim: "● ") + Text("Recording Take \(takeNumber)"))
                .foregroundStyle(.red)
        case .saving:
            Text("Saving recording…")
                .foregroundStyle(.secondary)
        }
    }
}

/// "2:10 · 3 takes", or just "2:12" before the first take.
enum PracticeTitleText {
    static func summary(duration: TimeInterval, takeCount: Int) -> String {
        let length = ClockText.duration(duration)
        guard takeCount > 0 else {
            return length
        }
        return length + " · " + String(localized: "\(takeCount) takes")
    }
}

private struct PracticeTransportControls: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        Button {
            viewModel.jump(by: -5)
        } label: {
            Label("Back 5 seconds", systemImage: "gobackward.5")
        }
        .disabled(viewModel.controlsLocked)
        .accessibilityLabel("Back 5 seconds")
        .help("Back 5 seconds")

        Button {
            viewModel.togglePlayback()
        } label: {
            Label(
                viewModel.isPlaying ? "Pause audio" : "Play audio",
                systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill"
            )
        }
        .disabled(viewModel.controlsLocked)
        .accessibilityLabel(viewModel.isPlaying ? "Pause audio" : "Play audio")

        Button {
            viewModel.jump(by: 5)
        } label: {
            Label("Forward 5 seconds", systemImage: "goforward.5")
        }
        .disabled(viewModel.controlsLocked)
        .accessibilityLabel("Forward 5 seconds")
        .help("Forward 5 seconds")
    }
}

private struct PracticeLoopRateVolumeControls: View {
    @ObservedObject var viewModel: PracticeViewModel
    @State private var isVolumePresented = false

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { viewModel.loopEnabled },
                set: { viewModel.setLoopEnabled($0) }
            )
        ) {
            Label(viewModel.loopEnabled ? "Disable loop" : "Enable loop", systemImage: "repeat")
        }
        .toggleStyle(.button)
        .disabled(!viewModel.canToggleLoop)
        .accessibilityLabel(viewModel.loopEnabled ? "Disable loop" : "Enable loop")
        .accessibilityValue(viewModel.loopEnabled ? "On" : "Off")
        .accessibilityHint(
            viewModel.region == nil
                ? "Select a practice region before enabling loop."
                : "Repeats only the selected region."
        )

        Menu {
            Picker(
                "Playback speed",
                selection: Binding(
                    get: { viewModel.rate },
                    set: { viewModel.setRate($0) }
                )
            ) {
                ForEach(PracticeViewModel.supportedRates, id: \.self) { rate in
                    Text(PracticeRateText.label(rate))
                        .tag(rate)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(PracticeRateText.label(viewModel.rate))
                .monospacedDigit()
        }
        .disabled(viewModel.controlsLocked)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(PracticeRateText.label(viewModel.rate))

        Button {
            isVolumePresented.toggle()
        } label: {
            Label("Playback volume", systemImage: volumeImage)
        }
        .popover(isPresented: $isVolumePresented, arrowEdge: .bottom) {
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
    }

    private var volumeImage: String {
        if viewModel.volume == 0 {
            return "speaker.slash"
        }
        return viewModel.volume < 0.5 ? "speaker.wave.1" : "speaker.wave.2"
    }
}

private struct PracticeRecordButton: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        if viewModel.recordingPresentation.locksPracticeControls {
            Button {
                viewModel.stopRecording()
            } label: {
                Label {
                    Text(stopTitle)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "stop.fill")
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(viewModel.recordingPresentation == .finalizing)
            .accessibilityLabel("Stop Recording")
        } else {
            Button {
                viewModel.startRecording()
            } label: {
                Label("Record", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(viewModel.controlsLocked)
            .accessibilityHint(
                """
                Starts recording from the current Original playhead until the audio ends, \
                or until you stop. With a take selected, recording replaces that take.
                """
            )
        }
    }

    private var stopTitle: LocalizedStringKey {
        if viewModel.recordingPresentation == .finalizing {
            return "Finishing…"
        }
        return "Stop \(ClockText.paddedPosition(viewModel.recordingElapsed))"
    }
}

private struct InspectorToggleButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(isPresented ? "Hide Subtitles" : "Show Subtitles", systemImage: "sidebar.right")
        }
        .help(isPresented ? "Hide Subtitles" : "Show Subtitles")
    }
}

enum PracticeRateText {
    static func label(_ rate: Double) -> String {
        rate == 1 ? "1.0×" : "\(rate.formatted())×"
    }
}

extension FormatStyle where Self == Date.FormatStyle {
    /// "Oct 4" / "10月4日", following the user's language.
    static var practiceDay: Date.FormatStyle {
        .dateTime.month(.abbreviated).day()
    }

    /// "Oct 4, 20:10" / "10月4日 20:10", following the user's language.
    static var practiceDayTime: Date.FormatStyle {
        .dateTime.month(.abbreviated).day().hour().minute()
    }
}
