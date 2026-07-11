import SwiftUI

struct RecordingsView: View {
    @ObservedObject var viewModel: RecordingsViewModel

    var body: some View {
        Group {
            if viewModel.items.isEmpty, !viewModel.isLoading {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Recordings")
        .task {
            await viewModel.load()
        }
        .alert(
            "Couldn’t Open Recording",
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无录音。", systemImage: "mic")
        } description: {
            Text("打开一个音频文件，开始第一次跟读练习。")
        } actions: {
            Button("Open Audio") {
                viewModel.openAudio()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.items) { item in
                    Button {
                        viewModel.open(item)
                    } label: {
                        recordingRow(item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.project.sourceDisplayName)
                    .accessibilityValue(
                        "\(item.takeCount) takes, \(item.lastRecordedAt.formatted(.relative(presentation: .named)))"
                    )
                }
            }
            .frame(maxWidth: 760)
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }

    private func recordingRow(_ item: RecordingListItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.project.sourceDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(
                    "\(item.takeCount) Takes · \(item.lastRecordedAt.formatted(.relative(presentation: .named)))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15))
        }
        .contentShape(Rectangle())
    }
}
