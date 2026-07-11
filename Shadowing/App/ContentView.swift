import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Files", systemImage: "folder")
                Label("Recordings", systemImage: "mic")
                Label("Settings", systemImage: "gearshape")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            ContentUnavailableView(
                "Open MP3",
                systemImage: "music.note",
                description: Text("Choose an audio file to start practicing.")
            )
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1080, height: 720)
}
