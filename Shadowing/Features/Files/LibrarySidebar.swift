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
    @Environment(\.backgroundProminence) private var prominence

    /// Gray icon and second line on every row, in light and dark. `.secondary` in a sidebar is
    /// vibrant, and vibrancy drops out of window captures (icons vanished, text turned black),
    /// so this uses the same gray as a plain color. On the accent selection it follows the
    /// selected text instead.
    private var secondaryTint: Color {
        prominence == .increased ? Color.white.opacity(0.75) : Color(nsColor: .secondaryLabelColor)
    }

    private var displayName: String {
        DisplayName.cleaned(item.project.sourceDisplayName)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 13))
                .foregroundStyle(secondaryTint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: displayName)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                LibraryRowSubtitle(item: item)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryTint)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Recording")
            }
        }
        .padding(.vertical, 3)
        .help(item.project.sourceDisplayName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open \(displayName)")
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
        let duration = ClockText.format(item.project.duration)
        if item.takeCount > 0 {
            return String(localized: "\(item.takeCount) takes · \(duration)")
        }
        return String(localized: "No takes yet · \(duration)")
    }
}
