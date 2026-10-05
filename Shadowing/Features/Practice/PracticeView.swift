import SwiftUI

struct PracticeView: View {
    @ObservedObject var viewModel: PracticeViewModel
    /// The full transcript (⌥⌘S). Hidden by default: shadowing is listening and speaking first.
    @AppStorage(SubtitlePreferences.transcriptKey) private var isInspectorPresented = false
    /// One subtitle line under the waveforms (toolbar "Subtitles" button).
    @AppStorage(SubtitlePreferences.captionKey) private var isCaptionVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OriginalWaveformSection(viewModel: viewModel, isCaptionVisible: isCaptionVisible)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            CompareBar(viewModel: viewModel)
                .padding(.horizontal, 20)
                .padding(.top, 14)
            TakesListSection(viewModel: viewModel)
                .padding(.top, 22)
        }
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
    }
}
