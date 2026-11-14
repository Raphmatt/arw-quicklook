import Cocoa

/// Bottom-left controls: two fixed-size icon buttons on a dark capsule.
///
/// Nothing in this corner may change while flipping through images — that
/// drew the eye away from the photo. So the capsule has a constant size, no
/// text (state is brightness only, details live in tooltips), and it is
/// invisible at rest: it fades in on real pointer movement and out after a
/// pause.
final class ControlsCapsule: NSView {

    /// Embedded preview ↔ full resolution.
    let layersButton = NSButton()
    /// Autofocus overlay on/off.
    let afButton = NSButton()

    private static let fadeIn: TimeInterval = 0.15
    private static let fadeOut: TimeInterval = 0.35
    private static let idleDelay: TimeInterval = 1.5
    private static let onAlpha: CGFloat = 1.0
    private static let offAlpha: CGFloat = 0.45
    private static let unavailableAlpha: CGFloat = 0.25

    private let stack = NSStackView()
    private var background: NSView?
    private var hideWork: DispatchWorkItem?
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Dark appearance → white symbols, independent of light/dark mode.
        appearance = NSAppearance(named: .darkAqua)

        configure(layersButton, symbol: "square.2.layers.3d", label: "Full resolution")
        configure(afButton, symbol: "dot.viewfinder", label: "Focus point")
        stack.setViews([layersButton, afButton], in: .leading)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        installBackground()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        alphaValue = restingAlpha
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure(_ button: NSButton, symbol: String, label: String) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.contentTintColor = .white
        // Toggle semantics for VoiceOver; the visual state is brightness.
        button.setButtonType(.pushOnPushOff)
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    // MARK: - State (brightness only — never size or text)

    /// Buttons always stay enabled: a disabled NSButton lets the click fall
    /// through to the Quick Look panel, which opens the file in its default app.
    func setLayers(showingFull: Bool, available: Bool, loading: Bool) {
        layersButton.image = NSImage(
            systemSymbolName: showingFull ? "square.2.layers.3d.fill" : "square.2.layers.3d",
            accessibilityDescription: "Full resolution")
        layersButton.state = showingFull ? .on : .off
        layersButton.alphaValue = !available ? Self.unavailableAlpha
            : showingFull ? Self.onAlpha : Self.offAlpha
        layersButton.toolTip = loading ? "Full resolution is loading"
            : !available ? "Full resolution is not available for this file"
            : showingFull ? "Showing full resolution — click for the camera's embedded preview"
            : "Showing the camera's embedded preview — click for full resolution"
    }

    /// `details` e.g. "AF-C · Wide · Face/Eye AF" (tooltip / VoiceOver value).
    func setAF(on: Bool, available: Bool, details: String) {
        afButton.state = on ? .on : .off
        afButton.alphaValue = !available ? Self.unavailableAlpha
            : on ? Self.onAlpha : Self.offAlpha
        let action = !available ? "" : on ? "Click to hide the focus frame" : "Click to show the focus frame"
        afButton.toolTip = [details, action].filter { !$0.isEmpty }.joined(separator: "\n")
        // VoiceOver reads on/off from the button state; mode details are help.
        afButton.setAccessibilityHelp(details)
    }

    // MARK: - Reveal / hide

    /// Shown permanently for VoiceOver users, or at half strength when the
    /// owner opted out of auto-hide (`controlsAlwaysVisible` in settings.plist,
    /// e.g. if pointer movement never reaches the extension).
    private var restingAlpha: CGFloat {
        if NSWorkspace.shared.isVoiceOverEnabled { return 1 }
        return Self.alwaysVisible ? 0.5 : 0
    }

    /// Read once per process: `reveal()` runs on every mouse move, and the
    /// setting lives in a plist on disk.
    private static let alwaysVisible = SharedSettings.controlsAlwaysVisible

    /// The panel can close under the pointer, so `mouseExited` never comes.
    func resetHover() {
        hovering = false
        hideWork?.cancel()
        alphaValue = restingAlpha
    }

    /// Called on real pointer movement over the preview.
    func reveal() {
        guard restingAlpha < 1 else { return }
        fade(to: 1, duration: Self.fadeIn)
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering else { return } // never hide under the pointer
            self.fade(to: self.restingAlpha, duration: Self.fadeOut)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: work)
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval) {
        guard abs(alphaValue - alpha) > 0.01 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            animator().alphaValue = alpha
        }
    }

    /// While invisible the capsule must not catch clicks — a view at alpha 0
    /// still would, toggling things nobody can see.
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue < 0.05 ? nil : super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        hideWork?.cancel()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        scheduleHide()
    }

    // MARK: - Background

    /// Liquid Glass (macOS 26+) tinted dark, or a dark HUD blur before that.
    /// With Reduce Transparency / Increase Contrast: a plain, nearly opaque
    /// black fill instead.
    private func installBackground() {
        background?.removeFromSuperview()
        let ws = NSWorkspace.shared
        let view: NSView
        if ws.accessibilityDisplayShouldReduceTransparency || ws.accessibilityDisplayShouldIncreaseContrast {
            view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
            view.layer?.cornerRadius = 13
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 13
            glass.tintColor = NSColor.black.withAlphaComponent(0.35)
            view = glass
        } else {
            let hud = NSVisualEffectView()
            hud.material = .hudWindow
            hud.blendingMode = .withinWindow
            hud.state = .active
            hud.wantsLayer = true
            hud.layer?.cornerRadius = 13
            hud.layer?.masksToBounds = true
            view = hud
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        background = view
    }

    @objc private func accessibilityChanged() {
        installBackground()
        alphaValue = max(alphaValue, restingAlpha)
    }
}

/// Root view of the preview. Reveals the controls on *real* pointer movement
/// only: Quick Look can deliver a mouse-moved event when a new image appears
/// under a resting pointer (arrow-key flipping), so the screen position is
/// compared with the last one seen by any preview instance.
final class PreviewRootView: NSView {
    weak var controls: ControlsCapsule?
    private static var lastMouse: NSPoint?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
        area = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        defer { Self.lastMouse = location }
        guard let last = Self.lastMouse else { return } // first sighting: no movement known
        if hypot(location.x - last.x, location.y - last.y) > 1 {
            controls?.reveal()
        }
    }
}
