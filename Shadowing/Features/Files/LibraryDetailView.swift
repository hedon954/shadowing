import SwiftUI

/// Detail column when no practice file is open: loading, empty library, or "pick a file".
struct LibraryDetailView: View {
    @ObservedObject var viewModel: FilesViewModel
    @ObservedObject var navigation: AppNavigationModel

    var body: some View {
        Group {
            if case let .loading(name) = viewModel.state {
                loading(name: name)
            } else if viewModel.libraryItems.isEmpty {
                ContentUnavailableView {
                    Label("No practice files yet", systemImage: "waveform")
                } description: {
                    Text("Drop an MP3 anywhere in this window to start")
                } actions: {
                    openButton
                }
            } else {
                ContentUnavailableView {
                    Label("Choose a practice file", systemImage: "waveform")
                } description: {
                    Text("Pick one in the sidebar, or drop an MP3 anywhere in this window.")
                } actions: {
                    openButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Shadowing")
        .toolbar {
            PlaceholderPracticeToolbar()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MP3 drop area")
        .accessibilityHint("Drop an MP3 here or use the Choose File button.")
        .alert(item: failureBinding) { failure in
            Alert(
                title: Text("Couldn’t Open Audio"),
                message: Text("\(failure.message)\n\n\(failure.suggestion)"),
                primaryButton: .default(Text(failure.recoveryTitle)) {
                    viewModel.recover()
                },
                secondaryButton: .cancel {
                    viewModel.dismissFailure()
                }
            )
        }
        .onChange(of: viewModel.state) { _, state in
            if state == .idle || state.failure != nil {
                navigation.selectedProjectID = navigation.currentProjectID
            }
        }
    }

    private var openButton: some View {
        Button("Open MP3…") {
            navigation.openAudioChooser()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Choose MP3 file")
    }

    private func loading(name: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading \(name)…")
                .foregroundStyle(.secondary)
            Button("Cancel") {
                viewModel.cancelLoading()
            }
            .accessibilityLabel("Cancel audio loading")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loading audio")
        .accessibilityValue(name)
    }

    private var failureBinding: Binding<FileLoadFailure?> {
        Binding(
            get: { viewModel.state.failure },
            set: { newValue in
                if newValue == nil {
                    viewModel.dismissFailure()
                }
            }
        )
    }
}
