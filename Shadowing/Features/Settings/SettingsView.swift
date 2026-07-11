import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Form {
                Section("Microphone") {
                    if viewModel.inputDevices.isEmpty {
                        Text("Using the system default input device.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "Input device",
                            selection: Binding(
                                get: { viewModel.selectedInputDeviceID ?? "" },
                                set: { id in
                                    viewModel.selectInputDevice(id: id.isEmpty ? nil : id)
                                }
                            )
                        ) {
                            Text("System Default").tag("")
                            ForEach(viewModel.inputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Input level")
                        ProgressView(value: Double(viewModel.inputLevel), total: 1)
                            .accessibilityLabel("Microphone input level")
                            .accessibilityValue("\(Int(viewModel.inputLevel * 100)) percent")
                    }
                }

                Section("Recording") {
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
                }

                Section("Playback") {
                    Picker(
                        "Default speed",
                        selection: Binding(
                            get: { viewModel.settings.defaultPlaybackRate },
                            set: { viewModel.setDefaultPlaybackRate($0) }
                        )
                    ) {
                        ForEach(AppSettings.supportedPlaybackRates, id: \.self) { rate in
                            Text(rate == 1 ? "1.0×" : "\(rate.formatted())×")
                                .tag(rate)
                        }
                    }
                }

                Section("Storage") {
                    LabeledContent("Recordings folder") {
                        Text(viewModel.storagePath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
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
