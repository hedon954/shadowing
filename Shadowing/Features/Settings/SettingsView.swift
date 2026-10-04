import SwiftUI

/// The app's Settings window (⌘,): Microphone, Recording, Playback and Storage tabs.
struct SettingsView: View {
    enum Tab: Hashable {
        case microphone
        case recording
        case playback
        case storage
    }

    @ObservedObject var viewModel: SettingsViewModel
    @State private var selection: Tab

    init(viewModel: SettingsViewModel, initialTab: Tab = .microphone) {
        self.viewModel = viewModel
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            MicrophoneSettingsTab(viewModel: viewModel)
                .tabItem {
                    Label("Microphone", systemImage: "mic")
                }
                .tag(Tab.microphone)
            RecordingSettingsTab(viewModel: viewModel)
                .tabItem {
                    Label("Recording (tab)", systemImage: "record.circle")
                }
                .tag(Tab.recording)
            PlaybackSettingsTab(viewModel: viewModel)
                .tabItem {
                    Label("Playback", systemImage: "play.circle")
                }
                .tag(Tab.playback)
            StorageSettingsTab(viewModel: viewModel)
                .tabItem {
                    Label("Storage", systemImage: "internaldrive")
                }
                .tag(Tab.storage)
        }
        .frame(width: 460)
        .task {
            await viewModel.load()
        }
        .onDisappear {
            viewModel.stop()
        }
        .alert(
            "Settings Error",
            isPresented: Binding(
                get: { viewModel.failureMessage != nil },
                set: {
                    if !$0 {
                        viewModel.failureMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.failureMessage = nil
            }
        } message: {
            Text(viewModel.failureMessage ?? "")
        }
    }
}

/// Shown under each tab while a recording is in progress, when the settings can't change.
private struct SettingsLockNote: View {
    let isLocked: Bool

    var body: some View {
        if isLocked {
            Label("Settings can't change while recording.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MicrophoneSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                if viewModel.inputDevices.isEmpty {
                    LabeledContent("Input Device") {
                        Text("Using the system default input device.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker(
                        "Input Device",
                        selection: Binding(
                            get: { viewModel.selectedInputDeviceID ?? "" },
                            set: { id in
                                viewModel.selectInputDevice(id: id.isEmpty ? nil : id)
                            }
                        )
                    ) {
                        Text("System Default").tag("")
                        ForEach(viewModel.inputDevices) { device in
                            Text(verbatim: device.name).tag(device.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
                LabeledContent("Input Level") {
                    InputLevelMeter(level: viewModel.inputLevel)
                        .accessibilityLabel("Microphone input level")
                        .accessibilityValue("\(Int(viewModel.inputLevel * 100)) percent")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        """
                        Speak into the microphone and the level should move. \
                        Recording uses the device selected here.
                        """
                    )
                    SettingsLockNote(isLocked: viewModel.isLocked)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(viewModel.isLocked)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RecordingSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker(
                    "Countdown",
                    selection: Binding(
                        get: { viewModel.settings.countdownSeconds },
                        set: { viewModel.setCountdownSeconds($0) }
                    )
                ) {
                    ForEach(AppSettings.supportedCountdownSeconds, id: \.self) { seconds in
                        Text(seconds == 0 ? "0 seconds" : "\(seconds) seconds")
                            .tag(seconds)
                    }
                }
                Toggle(
                    "Play original while recording",
                    isOn: Binding(
                        get: { viewModel.settings.playOriginalWhileRecording },
                        set: { viewModel.setPlayOriginalWhileRecording($0) }
                    )
                )
            } footer: {
                SettingsLockNote(isLocked: viewModel.isLocked)
            }
        }
        .formStyle(.grouped)
        .disabled(viewModel.isLocked)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PlaybackSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker(
                    "Default speed",
                    selection: Binding(
                        get: { viewModel.settings.defaultPlaybackRate },
                        set: { viewModel.setDefaultPlaybackRate($0) }
                    )
                ) {
                    ForEach(AppSettings.supportedPlaybackRates, id: \.self) { rate in
                        Text(verbatim: PracticeRateText.label(rate))
                            .tag(rate)
                    }
                }
            } footer: {
                SettingsLockNote(isLocked: viewModel.isLocked)
            }
        }
        .formStyle(.grouped)
        .disabled(viewModel.isLocked)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StorageSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Recordings folder") {
                    Text(verbatim: viewModel.storagePath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(viewModel.isLocked)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Segmented meter: green, then yellow near the top, red at the very top.
struct InputLevelMeter: View {
    static let segmentCount = 20
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< Self.segmentCount, id: \.self) { index in
                Rectangle()
                    .fill(segmentColor(index))
                    .frame(width: 6, height: 10)
            }
        }
    }

    private func segmentColor(_ index: Int) -> Color {
        index < Self.litSegments(for: level) ? Self.color(for: index) : Color.secondary.opacity(0.18)
    }

    static func litSegments(for level: Float) -> Int {
        guard level.isFinite else {
            return 0
        }
        return Int((min(max(level, 0), 1) * Float(segmentCount)).rounded())
    }

    private static func color(for index: Int) -> Color {
        switch index {
        case ..<13:
            .green
        case ..<17:
            .yellow
        default:
            .red
        }
    }
}
