import Foundation

/// Settings shared between the host app and the (sandboxed) extensions.
///
/// App Groups would be the textbook answer, but with ad-hoc signing macOS 15+
/// treats every rebuild as a different app and keeps re-prompting for group
/// container access. Instead the app and the Preview extension carry a sandbox temporary-exception
/// for `~/Library/Application Support/ARWQuickLook/` and share a plain plist
/// there. `NSHomeDirectory()` points into the sandbox container, so the real
/// home comes from the user database.
enum SharedSettings {

    private static let showFocusPointKey = "showFocusPoint"

    /// Whether the Quick Look preview draws the autofocus point overlay.
    static var showFocusPoint: Bool {
        get { (load()[showFocusPointKey] as? Bool) ?? true }
        set {
            var values = load()
            values[showFocusPointKey] = newValue
            save(values)
        }
    }

    private static let showFocusZonesKey = "showFocusZones"

    /// Whether general AF *areas* (Center / Zone / Flexible Spot frames) are
    /// drawn too. Off → only specific points and detected faces/eyes show.
    static var showFocusZones: Bool {
        get { (load()[showFocusZonesKey] as? Bool) ?? true }
        set {
            var values = load()
            values[showFocusZonesKey] = newValue
            save(values)
        }
    }

    private static let controlsAlwaysVisibleKey = "controlsAlwaysVisible"

    /// Keep the preview's controls visible (half strength) instead of hiding
    /// them until the pointer moves. No UI; set it in settings.plist if
    /// pointer movement doesn't reach the extension on some setup.
    static var controlsAlwaysVisible: Bool {
        (load()[controlsAlwaysVisibleKey] as? Bool) ?? false
    }

    // MARK: - Plist storage

    private static var settingsURL: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) })
        else { return nil }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/ARWQuickLook/settings.plist")
    }

    private static func load() -> [String: Any] {
        guard let url = settingsURL,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return [:] }
        return plist as? [String: Any] ?? [:]
    }

    private static func save(_ values: [String: Any]) {
        guard let url = settingsURL,
              let data = try? PropertyListSerialization.data(fromPropertyList: values,
                                                             format: .xml, options: 0)
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
