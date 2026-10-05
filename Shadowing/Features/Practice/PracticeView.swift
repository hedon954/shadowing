import SwiftUI

struct PracticeView: View {
    @ObservedObject var viewModel: PracticeViewModel
    /// The full transcript (⌥⌘S). Hidden by default: shadowing is listening and speaking first.
    @AppStorage(SubtitlePreferences.transcriptKey) private var isInspectorPresented = false
    /// One subtitle line under the waveforms (toolbar "Subtitles" button).
    @AppStorage(SubtitlePreferences.captionKey) private var isCaptionVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OriginalWaveformSection(viewModel: viewModel)
                .padding(.horizontal, 20)
            if isCaptionVisible {
                SubtitleCaptionLine(viewModel: viewModel, subtitles: viewModel.subtitles)
                    .padding(.horizontal, 20)
            }
            TakesListSection(viewModel: viewModel)
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PracticeControlBar(viewModel: viewModel)
                .padding(PracticeControlBar.inset)
        }
        .navigationTitle(DisplayName.cleaned(viewModel.project.sourceDisplayName))
        .toolbar(removing: .title)
        .toolbar {
            PracticeToolbar(viewModel: viewModel, isCaptionVisible: $isCaptionVisible)
        }
        .inspector(isPresented: $isInspectorPresented) {
            SubtitlesInspector(viewModel: viewModel, subtitles: viewModel.subtitles)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
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
    }
}
