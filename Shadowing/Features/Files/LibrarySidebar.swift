import SwiftUI

struct LibrarySidebar: View {
    @ObservedObject var viewModel: FilesViewModel
    @ObservedObject var navigation: AppNavigationModel

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                if viewModel.libraryItems.isEmpty {
                    Text("No practice files yet")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(viewModel.libraryItems) { item in
                        LibrarySidebarRow(
                            item: item,
                            isRecording: navigation.isRecording(projectID: item.id)
                        )
                        .tag(item.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .task {
            await viewModel.loadLibrary()
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { navigation.selectedProjectID },
            set: { id in
                guard let id, let item = viewModel.libraryItems.first(where: { $0.id == id }) else {
                    return
                }
                navigation.openLibraryItem(item)
            }
        )
    }

    private var footer: some View {
        Button {
            navigation.openAudioChooser()
        } label: {
            Label("Open MP3…", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Choose MP3 file")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct LibrarySidebarRow: View {
    let item: LibraryProjectItem
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.project.sourceDisplayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                LibraryRowSubtitle(item: item)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Recording")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open \(item.project.sourceDisplayName)")
        .accessibilityValue(Text(LibraryRowSubtitle.accessibilityText(for: item)))
    }
}

/// "3 takes · 20:49" or "No takes yet · 15:04".
struct LibraryRowSubtitle: View {
    let item: LibraryProjectItem

    var body: some View {
        Text(Self.accessibilityText(for: item))
    }

    static func accessibilityText(for item: LibraryProjectItem) -> String {
        let duration = ClockText.duration(item.project.duration)
        if item.takeCount > 0 {
            return String(localized: "\(item.takeCount) takes · \(duration)")
        }
        return String(localized: "No takes yet · \(duration)")
    }
}
