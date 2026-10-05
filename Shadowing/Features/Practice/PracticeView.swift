import SwiftUI

struct PracticeView: View {
    @ObservedObject var viewModel: PracticeViewModel
    @State private var isInspectorPresented = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OriginalWaveformSection(viewModel: viewModel)
                .padding(.horizontal, 20)
            TakesListSection(viewModel: viewModel)
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(DisplayName.cleaned(viewModel.project.sourceDisplayName))
        .toolbar(removing: .title)
        .toolbar {
            PracticeToolbar(viewModel: viewModel, isInspectorPresented: $isInspectorPresented)
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
