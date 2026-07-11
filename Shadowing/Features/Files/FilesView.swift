import SwiftUI

struct FilesView: View {
    @ObservedObject var viewModel: FilesViewModel
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                dropZone
                recentProjects
            }
            .frame(maxWidth: 760)
            .padding(36)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Files")
        .task {
            await viewModel.loadRecentProjects()
        }
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
        .overlay {
            if case let .loading(name) = viewModel.state {
                loadingOverlay(name: name)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 82, height: 82)
                .background(.tint.opacity(0.09), in: Circle())

            VStack(spacing: 6) {
                Text("Open MP3")
                    .font(.title2.weight(.semibold))
                Text("Drag an audio file here or choose one from your Mac.")
                    .foregroundStyle(.secondary)
            }

            Button("Choose File") {
                viewModel.chooseFile()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Choose MP3 file")
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else {
                return false
            }
            viewModel.acceptDroppedFile(url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MP3 drop area")
        .accessibilityHint("Drop an MP3 here or use the Choose File button.")
    }

    @ViewBuilder
    private var recentProjects: some View {
        if viewModel.recentProjects.isEmpty {
            ContentUnavailableView(
                "No Recent Files",
                systemImage: "clock",
                description: Text("MP3 files you open will appear here.")
            )
            .frame(maxWidth: .infinity, minHeight: 150)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent")
                    .font(.headline)

                ForEach(viewModel.recentProjects) { project in
                    Button {
                        viewModel.openRecentProject(project)
                    } label: {
                        recentRow(project)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(project.sourceDisplayName)")
                    .accessibilityValue(accessibilityValue(for: project))
                }
            }
        }
    }

    private func recentRow(_ project: AudioProject) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(project.sourceDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label(formatDuration(project.duration), systemImage: "clock")
                    Text(project.lastOpenedAt.formatted(.relative(presentation: .named)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Start Practice")
                .font(.callout.weight(.medium))
                .foregroundStyle(.tint)
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

    private func loadingOverlay(name: String) -> some View {
        ZStack {
            Color.black.opacity(0.08)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading \(name)…")
                    .font(.headline)
                Button("Cancel") {
                    viewModel.cancelLoading()
                }
                .accessibilityLabel("Cancel audio loading")
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 12)
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func accessibilityValue(for project: AudioProject) -> String {
        let relativeDate = project.lastOpenedAt.formatted(.relative(presentation: .named))
        return "\(formatDuration(project.duration)), last opened \(relativeDate)"
    }
}
