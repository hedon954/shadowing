import SwiftUI

struct PracticeView: View {
    @ObservedObject var viewModel: PracticeViewModel
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if viewModel.showsMultiTrackWorkspace {
                    RecordingWorkspaceView(viewModel: viewModel)
                } else {
                    waveform
                }
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
        }
        .navigationTitle("Practice")
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            Task {
                await viewModel.close()
            }
        }
        .modifier(PracticeAlertsModifier(viewModel: viewModel))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                viewModel.requestLeave {
                    onBack()
                }
            } label: {
                Label("Files", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Back to Files")

            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(.tint)

            Text(viewModel.project.sourceDisplayName)
                .font(.title2.weight(.semibold))
                .lineLimit(1)

            Spacer()
        }
    }

    private var waveform: some View {
        VStack(spacing: 8) {
            WaveformView(
                waveform: viewModel.waveform,
                playhead: viewModel.playhead,
                duration: viewModel.project.duration,
                region: viewModel.region,
                viewport: viewModel.timelineViewport,
                isEnabled: !viewModel.controlsLocked,
                onSeek: { position in
                    viewModel.seek(to: position)
                },
                onRegionChanged: { region in
                    viewModel.selectRegion(region)
                },
                onRegionCleared: viewModel.clearRegion,
                onViewportChanged: viewModel.setTimelineViewport,
                onGestureActiveChanged: viewModel.setTimelineGestureActive,
                onShowFull: viewModel.showFullTimeline,
                onFitRegion: viewModel.fitTimelineToRegion
            )

            HStack {
                Text(format(viewModel.playhead))
                Spacer()
                Text(format(viewModel.project.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if let warning = viewModel.waveform.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Waveform warning: \(warning)")
            }

            if let region = viewModel.region {
                HStack {
                    Label(
                        "\(format(region.start)) – \(format(region.end))",
                        systemImage: "selection.pin.in.out"
                    )
                    Spacer()
                    Text("\(region.duration.formatted(.number.precision(.fractionLength(1)))) s")
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Selected region from \(format(region.start)) to \(format(region.end))"
                )
            } else {
                Label("Drag across the waveform to select one sentence.", systemImage: "cursorarrow.motionlines")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button {
                viewModel.jump(by: -5)
            } label: {
                Label("Back 5 seconds", systemImage: "gobackward.5")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(viewModel.controlsLocked)
            .accessibilityLabel("Back 5 seconds")

            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.controlsLocked)
            .accessibilityLabel(viewModel.isPlaying ? "Pause audio" : "Play audio")

            Button {
                viewModel.jump(by: 5)
            } label: {
                Label("Forward 5 seconds", systemImage: "goforward.5")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(viewModel.controlsLocked)
            .accessibilityLabel("Forward 5 seconds")

            Button {
                viewModel.setLoopEnabled(!viewModel.loopEnabled)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(viewModel.loopEnabled ? .accentColor : .secondary)
            .disabled(!viewModel.canToggleLoop)
            .accessibilityLabel(viewModel.loopEnabled ? "Disable loop" : "Enable loop")
            .accessibilityValue(viewModel.loopEnabled ? "On" : "Off")
            .accessibilityHint(
                viewModel.region == nil
                    ? "Select a practice region before enabling loop."
                    : "Repeats only the selected region."
            )

            Spacer(minLength: 10)

            Picker(
                "Playback speed",
                selection: Binding(
                    get: { viewModel.rate },
                    set: { rate in
                        viewModel.setRate(rate)
                    }
                )
            ) {
                ForEach(PracticeViewModel.supportedRates, id: \.self) { rate in
                    Text(rateLabel(rate))
                        .tag(rate)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 105)
            .accessibilityLabel("Playback speed")
            .accessibilityValue(rateLabel(viewModel.rate))
            .disabled(viewModel.controlsLocked)

            Image(systemName: volumeImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { viewModel.volume },
                    set: { volume in
                        viewModel.setVolume(volume)
                    }
                ),
                in: 0 ... 1
            )
            .frame(width: 150)
            .accessibilityLabel("Playback volume")
            .accessibilityValue("\(Int(viewModel.volume * 100)) percent")

            Button {
                viewModel.startRecording()
            } label: {
                Label("Record", systemImage: "mic.fill")
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
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private var volumeImage: String {
        if viewModel.volume == 0 {
            return "speaker.slash"
        }
        return viewModel.volume < 0.5 ? "speaker.wave.1" : "speaker.wave.2"
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == 1 ? "1.0×" : "\(rate.formatted())×"
    }

    private func format(_ time: TimeInterval) -> String {
        let totalSeconds = max(Int(time.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
