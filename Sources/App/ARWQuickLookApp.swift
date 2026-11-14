import SwiftUI

@main
struct ARWQuickLookApp: App {
    var body: some Scene {
        Window("ARW QuickLook", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
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
            SettingsLink {
                Text("Settings…")
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(width: 420, height: 360)
    }
}

struct SettingsView: View {
    @State private var showFocusPoint = SharedSettings.showFocusPoint
    @State private var showFocusZones = SharedSettings.showFocusZones

    var body: some View {
        Form {
            Toggle("Show focus point (AF) overlay", isOn: $showFocusPoint)
                .onChange(of: showFocusPoint) { _, value in
                    SharedSettings.showFocusPoint = value
                }
            Text("Draws a green frame where the camera focused (a picked point "
                 + "or a detected face/eye), read from the Sony metadata in the "
                 + "file. Can also be toggled with the AF button in the Quick Look "
                 + "panel itself.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("Show general AF areas", isOn: $showFocusZones)
                .onChange(of: showFocusZones) { _, value in
                    SharedSettings.showFocusZones = value
                }
                .disabled(!showFocusPoint)
                .padding(.top, 8)
            Text("For Center, Zone and Flexible Spot shots the camera only "
                 + "records the area it focused within, not a point. These are "
                 + "drawn as white corner brackets instead of a green frame.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            showFocusPoint = SharedSettings.showFocusPoint
            showFocusZones = SharedSettings.showFocusZones
        }
    }
}
