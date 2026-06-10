import SwiftUI

@main
struct ARWQuickLookApp: App {
    var body: some Scene {
        Window("ARW QuickLook", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            Text("ARW QuickLook")
                .font(.title.bold())
            Text("Fast previews for Sony ARW files.")
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("Enable the extensions under:\nSystem Settings › General ›\nLogin Items & Extensions › Quick Look")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 420, height: 320)
    }
}
