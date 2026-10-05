import SwiftUI

struct PracticeView: View {
    @ObservedObject var viewModel: PracticeViewModel
    /// The full transcript inspector (⌥⌘I). Hidden by default: shadowing is listening and
    /// speaking first. Works whether or not the one-line subtitle is on.
    @AppStorage(SubtitlePreferences.transcriptKey) private var isInspectorPresented = false
    /// One subtitle line under the waveforms (⌥⌘S); hidden while the transcript is open.
    @AppStorage(SubtitlePreferences.captionKey) private var isCaptionVisible = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OriginalWaveformSection(
                viewModel: viewModel,
                isCaptionVisible: isCaptionVisible && !isInspectorPresented
            )
            .padding(.horizontal, 20)
            .padding(.top, 4)
            CompareBar(viewModel: viewModel)
                .padding(.horizontal, 20)
                .padding(.top, 14)
            TakesListSection(viewModel: viewModel)
                .padding(.top, 22)
        }
        // minWidth 0: the split view adds the floating sidebar's width to the detail's minimum,
        // so any content minimum here pushes the inspector past the window's right edge.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PracticeControlBar(viewModel: viewModel)
                .padding(PracticeControlBar.inset)
                .frame(minWidth: 0, maxWidth: .infinity)
        }
        .navigationTitle(DisplayName.cleaned(viewModel.project.sourceDisplayName))
        .navigationSubtitle(
            PracticeTitleText.subtitle(for: viewModel.headerStatus, duration: viewModel.project.duration)
        )
        .toolbar {
            PracticeToolbar(isCaptionVisible: $isCaptionVisible, isTranscriptVisible: $isInspectorPresented)
        }
        .inspector(isPresented: $isInspectorPresented) {
            SubtitlesInspector(viewModel: viewModel, subtitles: viewModel.subtitles)
                .inspectorColumnWidth(min: 260, ideal: 330, max: 440)
        }
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            Task {
                await viewModel.close()
            }
        }
        .modifier(PracticeAlertsModifier(viewModel: viewModel))
        .focusedSceneValue(\.practiceCanDeleteTake, viewModel.activeTake != nil && !viewModel.controlsLocked)
        .onAppear {
            viewModel.undoManager = undoManager
        }
        .onChange(of: undoManager) {
            viewModel.undoManager = undoManager
        }
    }
}
