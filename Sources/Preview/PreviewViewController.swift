import Cocoa
import IOSurface
import Quartz // QLPreviewingController

/// Clip view that keeps the document centered when it's smaller than the viewport
/// (so a fitted/letterboxed image sits in the middle instead of the bottom-left).
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let df = doc.frame
        if rect.width > df.width { rect.origin.x = (df.width - rect.width) / 2 }
        if rect.height > df.height { rect.origin.y = (df.height - rect.height) / 2 }
        return rect
    }
}

/// Serializes full-resolution decodes so at most one render runs at a time.
/// A queued decode whose task was cancelled while waiting (user moved to another
/// image) bails out before doing any work.
actor FullResDecoder {
    func decode(url: URL) throws -> IOSurface? {
        try Task.checkCancellation()
        return ARWImageLoader.fullDecode(url: url)
    }
}

/// Document view holding the embedded preview and the full-resolution image as
/// two sublayers. Both stay visible in the render tree (Core Animation drops
/// the texture of a hidden layer); toggling flips their stacking order.
final class ImageCanvasView: NSView {
    private let embeddedLayer = CALayer()
    private let fullLayer = CALayer()
    /// Autofocus frame outline for a specific point / detected subject, drawn
    /// on top of both image layers.
    private let focusLayer = CALayer()
    /// Corner brackets for a general AF area (Center / Zone / Flexible Spot) —
    /// visibly different from a point, like the camera's own zone display.
    private let zoneLayer = CAShapeLayer()
    private var focusInfo: SonyFocusInfo?
    private var focusVisible = false
    private var zonesVisible = true
    /// The canvas lives at native pixel size and is scaled down by the scroll
    /// view's magnification — divide by it so the outline stays ~2 pt on screen.
    private var focusScale: CGFloat = 1

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for sublayer in [embeddedLayer, fullLayer] {
            sublayer.contentsGravity = .resize
            sublayer.magnificationFilter = .linear
            sublayer.minificationFilter = .trilinear
            sublayer.isOpaque = true
            layer?.addSublayer(sublayer)
        }
        focusLayer.borderColor = NSColor.systemGreen.cgColor
        focusLayer.zPosition = 2
        focusLayer.isHidden = true
        layer?.addSublayer(focusLayer)

        zoneLayer.fillColor = nil
        zoneLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        zoneLayer.lineCap = .round
        zoneLayer.shadowColor = NSColor.black.cgColor
        zoneLayer.shadowOpacity = 0.6
        zoneLayer.shadowOffset = .zero
        zoneLayer.zPosition = 2
        zoneLayer.isHidden = true
        layer?.addSublayer(zoneLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        withoutAnimation {
            embeddedLayer.frame = bounds
            fullLayer.frame = bounds
            layoutFocusLayer()
        }
    }

    func reset() {
        withoutAnimation {
            embeddedLayer.contents = nil
            fullLayer.contents = nil
            focusInfo = nil
            updateFocusVisibility()
        }
    }

    // MARK: - Focus point overlay

    func setFocus(_ info: SonyFocusInfo?, visible: Bool, showZones: Bool) {
        focusInfo = info
        focusVisible = visible
        zonesVisible = showZones
        withoutAnimation {
            updateFocusVisibility()
            layoutFocusLayer()
        }
    }

    func setFocusVisible(_ visible: Bool) {
        focusVisible = visible
        withoutAnimation { updateFocusVisibility() }
    }

    /// Point → green box; area → corner brackets (unless areas are switched off).
    private func updateFocusVisibility() {
        let info = focusVisible ? focusInfo.flatMap { $0.isManualFocus ? nil : $0 } : nil
        focusLayer.isHidden = !(info.map { !$0.isZone } ?? false)
        zoneLayer.isHidden = !(info.map { $0.isZone && zonesVisible } ?? false)
    }

    /// Call whenever the scroll view's magnification changes.
    func setFocusScale(_ magnification: CGFloat) {
        let scale = max(magnification, 0.001)
        guard abs(scale - focusScale) > 0.0001 else { return }
        focusScale = scale
        withoutAnimation { layoutFocusLayer() }
    }

    private func layoutFocusLayer() {
        guard let info = focusInfo, bounds.width > 0, bounds.height > 0 else { return }
        // Normalized coords use a top-left origin; the view is bottom-left.
        let w = info.size.width * bounds.width
        let h = info.size.height * bounds.height
        let rect = CGRect(x: info.center.x * bounds.width - w / 2,
                          y: (1 - info.center.y) * bounds.height - h / 2,
                          width: w, height: h)
        focusLayer.frame = rect
        focusLayer.borderWidth = 2 / focusScale
        focusLayer.cornerRadius = 3 / focusScale

        // Brackets: each corner's arms are 18 % of the shorter side.
        zoneLayer.frame = rect
        let arm = min(w, h) * 0.18
        let r = CGRect(origin: .zero, size: rect.size)
        let path = CGMutablePath()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: r.minX, y: r.minY), arm, arm),
            (CGPoint(x: r.maxX, y: r.minY), -arm, arm),
            (CGPoint(x: r.minX, y: r.maxY), arm, -arm),
            (CGPoint(x: r.maxX, y: r.maxY), -arm, -arm),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x + dx, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy))
        }
        zoneLayer.path = path
        zoneLayer.lineWidth = 2.5 / focusScale
        zoneLayer.shadowRadius = 2 / focusScale
    }

    func setEmbedded(_ image: CGImage) {
        withoutAnimation {
            embeddedLayer.contents = image
            embeddedLayer.zPosition = 1
            fullLayer.zPosition = 0
        }
    }

    /// Installs the full-res IOSurface behind the embedded layer.
    func setFull(_ surface: IOSurface) {
        withoutAnimation { fullLayer.contents = surface }
    }

    func showFull(_ full: Bool) {
        withoutAnimation {
            fullLayer.zPosition = full ? 1 : 0
            embeddedLayer.zPosition = full ? 0 : 1
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// Quick Look preview panel for Sony ARW.
///
/// - Embedded preview shown instantly (~20 ms warm), fit to the panel.
/// - Full-resolution decode starts immediately in the background and swaps in
///   without changing the framing (same zoom/scroll — it just gets sharper).
///   Moving to another image cancels it; only rapid flipping stays on embedded.
/// - The status chip (bottom left) names what's on screen and toggles between
///   the cached embedded and full versions.
/// - Pinch / double-tap to zoom, free two-finger panning — like Preview.app.
final class PreviewViewController: NSViewController, QLPreviewingController {

    private let scrollView = NSScrollView()
    private let canvas = ImageCanvasView()
    /// Status chip in the bottom-left controls capsule: "Preview" / "Full".
    /// Deliberately no loading indicator — it flickered on every image.
    private let statusButton = NSButton()
    /// Toggles the autofocus-point overlay; hidden when the file has no AF data.
    private let afButton = NSButton()
    private static let decoder = FullResDecoder()

    private var currentURL: URL?
    private var fullResTask: Task<Void, Never>?
    /// Bumped on every start/cancel; only the decode holding the current value
    /// may update the chip and canvas.
    private var decodeGeneration = 0
    private var state: LoadState = .preview
    private var hasEmbedded = false
    private var hasFull = false
    private var focusInfo: SonyFocusInfo?
    private var showFocus = true

    /// True while the image is fit-to-window (so we refit on resize). Cleared once
    /// the user zooms/pans (detected via live-scroll/live-magnify, which only fire
    /// for user gestures — programmatic `scroll(_:)` does not trigger them).
    private var isFitted = true

    // MARK: - View

    override func loadView() {
        // Transparent everywhere — letterbox areas show QuickLook's own panel
        // background instead of a hard black fill.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 680))
        root.wantsLayer = true

        let clip = CenteringClipView()
        clip.drawsBackground = false

        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.allowsMagnification = true
        scrollView.maxMagnification = 16
        // Free 2-D panning like Preview.app — without this, scrolling locks to
        // the dominant axis and diagonal pans are impossible.
        scrollView.usesPredominantAxisScrolling = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        configureStatusButton()
        configureAFButton()

        let pill = makeControlsPill(arrangedSubviews: [statusButton, afButton])
        root.addSubview(pill)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            pill.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            pill.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(userInteracted),
            name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(userInteracted),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        // Keeps the focus outline at a constant on-screen width across zoom
        // changes from any source (pinch, smart magnify, programmatic).
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clip)

        view = root
    }

    private enum LoadState {
        case preview, loading, full
    }

    /// Groups the controls on one capsule that stays legible over any photo, in
    /// light and dark mode: the capsule is forced to the dark appearance and
    /// tinted, so it is always white-on-dark, independent of the image
    /// underneath. Liquid Glass on macOS 26+, a dark HUD blur before that.
    private func makeControlsPill(arrangedSubviews: [NSView]) -> NSView {
        let stack = NSStackView(views: arrangedSubviews)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.detachesHiddenViews = true // AF hidden → capsule shrinks

        let pill: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 13
            // Darkening tint so white text keeps contrast over bright skies/snow.
            glass.tintColor = NSColor.black.withAlphaComponent(0.35)
            glass.contentView = stack
            pill = glass
        } else {
            let hud = NSVisualEffectView()
            hud.material = .hudWindow
            hud.blendingMode = .withinWindow
            hud.state = .active
            hud.wantsLayer = true
            hud.layer?.cornerRadius = 13
            hud.layer?.masksToBounds = true
            stack.translatesAutoresizingMaskIntoConstraints = false
            hud.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: hud.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: hud.trailingAnchor),
                stack.topAnchor.constraint(equalTo: hud.topAnchor),
                stack.bottomAnchor.constraint(equalTo: hud.bottomAnchor),
            ])
            pill = hud
        }
        // Dark appearance → white labels, regardless of the
        // system light/dark setting.
        pill.appearance = NSAppearance(named: .darkAqua)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return pill
    }

    /// Borderless label-style button for use inside the controls capsule.
    private func styleChip(_ button: NSButton) {
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureStatusButton() {
        styleChip(statusButton)
        statusButton.target = self
        statusButton.action = #selector(chipClicked)
        setState(.preview)
    }

    private func configureAFButton() {
        styleChip(afButton)
        afButton.title = "AF"
        afButton.target = self
        afButton.action = #selector(afClicked)
        afButton.isHidden = true
    }

    /// Chip reads e.g. "AF · Wide"; the tooltip adds focus mode and subject
    /// detection ("AF-C · Wide · Face/Eye AF"). Dimmed = overlay off.
    private func updateAFButton() {
        afButton.isHidden = focusInfo == nil
        if focusInfo?.isManualFocus == true {
            afButton.title = "MF" // no frame drawn — nothing to toggle
        } else {
            afButton.title = focusInfo?.areaMode.map { "AF · \($0)" } ?? "AF"
        }
        afButton.alphaValue = showFocus ? 1.0 : 0.45
        let details = [focusInfo?.focusMode, focusInfo?.areaMode, focusInfo?.tracking]
            .compactMap { $0 }.joined(separator: " · ")
        let action = showFocus ? "Click to hide focus frame" : "Click to show focus frame"
        afButton.toolTip = details.isEmpty ? action : "\(details)\n\(action)"
    }

    @objc private func afClicked() {
        // Manual focus draws no frame — nothing to toggle, and the saved
        // setting must not flip silently.
        guard let info = focusInfo, !info.isManualFocus else { return }
        showFocus.toggle()
        SharedSettings.showFocusPoint = showFocus
        canvas.setFocusVisible(showFocus)
        updateAFButton()
    }

    @objc private func clipBoundsChanged() {
        canvas.setFocusScale(scrollView.magnification)
    }

    /// The chip stays enabled in every state — a disabled NSButton lets the
    /// click fall through to the Quick Look panel, which opens the file in its
    /// default app. The title names what you're looking at; clicking toggles.
    private func setState(_ state: LoadState) {
        self.state = state
        switch state {
        case .preview:
            statusButton.title = "Preview"
            statusButton.toolTip = hasFull
                ? "Click to show full resolution"
                : "Click to load full resolution"
        case .loading:
            statusButton.title = "Preview" // stays put while decoding — no flicker
            statusButton.toolTip = nil
        case .full:
            statusButton.title = "Full"
            statusButton.toolTip = "Click to show embedded preview"
        }
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
        // Quick Look may re-prepare the same file (e.g. window state changes).
        // Everything is already loaded — don't wipe the caches and re-decode.
        // If the panel was closed mid-decode (viewWillDisappear cancelled it),
        // resume the full-resolution load instead of staying on the preview.
        if url == currentURL, hasEmbedded {
            if !hasFull, fullResTask == nil { startFullRes(for: url) }
            return
        }

        cancelFullRes()
        currentURL = url
        isFitted = true
        hasEmbedded = false
        hasFull = false
        focusInfo = nil
        canvas.reset()
        updateAFButton()
        setState(.preview)

        let px = targetPixelSize()
        async let focusTask = Task.detached(priority: .userInitiated) {
            SonyFocusInfo.read(url: url)
        }.value
        if let preview = await detachedDecode({ ARWImageLoader.embeddedPreview(url: url, maxPixelSize: px) }),
           currentURL == url {
            hasEmbedded = true
            setPreferredSize(aspect: CGSize(width: preview.width, height: preview.height))
            canvas.frame = NSRect(x: 0, y: 0, width: preview.width, height: preview.height)
            canvas.setEmbedded(preview)
            fitAndCenter()
        }

        if let focus = await focusTask, currentURL == url {
            focusInfo = focus
            showFocus = SharedSettings.showFocusPoint
            canvas.setFocus(focus, visible: showFocus, showZones: SharedSettings.showFocusZones)
            updateAFButton()
        }

        guard currentURL == url else { return } // superseded while awaiting

        // Nothing to show yet (no embedded preview): wait for the full image
        // here, so a file that can't be read at all throws and Quick Look
        // shows its generic fallback instead of an empty panel.
        if !hasEmbedded {
            startFullRes(for: url)
            await fullResTask?.value
            if currentURL == url, !hasFull { throw CocoaError(.fileReadCorruptFile) }
            return
        }

        // Full resolution starts right away — only rapid flipping stays on the
        // embedded preview, because moving to another file cancels this task.
        startFullRes(for: url)
    }

    // MARK: - Display

    /// Install the full-res image and make it visible, preserving the user's
    /// framing if they have zoomed/panned (same spot, just sharper).
    private func attachFull(_ surface: IOSurface) {
        let size = NSSize(width: surface.width, height: surface.height)

        if !isFitted, canvas.frame.width > 0 {
            let oldW = canvas.frame.width, oldH = canvas.frame.height
            let vis = scrollView.contentView.documentVisibleRect
            let fracX = vis.midX / oldW, fracY = vis.midY / oldH
            let oldMag = scrollView.magnification

            canvas.setFull(surface)
            canvas.frame = NSRect(origin: .zero, size: size)
            // Lower the floor first — magnification values shrink with the larger
            // image, and setting magnification below the old floor would clamp.
            scrollView.minMagnification = fitMagnification(for: size)
            scrollView.magnification = oldMag * oldW / size.width
            let newVis = scrollView.contentView.documentVisibleRect
            canvas.scroll(NSPoint(x: fracX * size.width - newVis.width / 2,
                                  y: fracY * size.height - newVis.height / 2))
            canvas.showFull(true)
            canvas.setFocusScale(scrollView.magnification)
            return
        }

        canvas.setFull(surface)
        canvas.frame = NSRect(origin: .zero, size: size)
        canvas.showFull(true)
        fitAndCenter()
    }

    private func fitMagnification(for imageSize: NSSize) -> CGFloat {
        let b = scrollView.bounds.size
        guard imageSize.width > 0, imageSize.height > 0, b.width > 1, b.height > 1 else { return 1 }
        return min(b.width / imageSize.width, b.height / imageSize.height)
    }

    private func fitAndCenter() {
        let fit = fitMagnification(for: canvas.frame.size)
        // Fit IS the floor — zooming out past it would expose empty borders.
        scrollView.minMagnification = fit
        scrollView.magnification = fit
        let doc = canvas.frame.size
        let vis = scrollView.contentView.documentVisibleRect
        canvas.scroll(NSPoint(x: (doc.width - vis.width) / 2,
                              y: (doc.height - vis.height) / 2))
        canvas.setFocusScale(fit)
        isFitted = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard hasEmbedded || hasFull else { return }
        if isFitted {
            fitAndCenter() // QuickLook resized the panel — refit to the real size.
        } else {
            scrollView.minMagnification = fitMagnification(for: canvas.frame.size)
        }
    }

    @objc private func userInteracted() { isFitted = false }

    // MARK: - Full resolution

    private func startFullRes(for url: URL) {
        decodeGeneration &+= 1
        let generation = decodeGeneration
        setState(.loading)
        fullResTask = Task { [weak self] in
            await self?.runFullDecode(url: url, generation: generation)
        }
    }

    /// Toggle between the cached embedded and full-resolution versions.
    @objc private func chipClicked() {
        switch state {
        case .loading:
            return // decode already running; swallow the click
        case .full:
            guard hasEmbedded else { return }
            canvas.showFull(false)
            setState(.preview)
        case .preview:
            if hasFull {
                canvas.showFull(true)
                setState(.full)
            } else if fullResTask == nil, let url = currentURL {
                startFullRes(for: url)
            }
        }
    }

    private func runFullDecode(url: URL, generation: Int) async {
        // Serialized through the actor; throws (returns nil) if this task was
        // cancelled while waiting its turn or before the render started.
        let full = try? await Self.decoder.decode(url: url)

        // A superseded decode (cancelled, or a newer one started meanwhile)
        // must not touch the UI — it would flip the chip under a newer decode.
        // cancelFullRes() already restored the state for it.
        guard generation == decodeGeneration, !Task.isCancelled, currentURL == url else { return }
        fullResTask = nil
        if let full {
            hasFull = true
            attachFull(full)
            setState(.full)
        } else {
            setState(.preview)
        }
    }

    /// Cancels a pending decode and leaves the UI consistent: the chip
    /// never stays in the loading state (the cancelled task won't reset it itself).
    private func cancelFullRes() {
        fullResTask?.cancel()
        fullResTask = nil
        decodeGeneration &+= 1
        if state == .loading { setState(hasFull ? .full : .preview) }
    }


    // MARK: - Helpers

    private func detachedDecode(_ work: @escaping () -> CGImage?) async -> CGImage? {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// Size the panel to fill the screen at the image's aspect ratio, like the
    /// native Quick Look does for JPEGs. `aspectFit` is the wrong tool here — it
    /// never upscales, so it would leave the window at the embedded preview's
    /// ~1616 px and waste most of the screen. Scale up to the screen instead.
    private func setPreferredSize(aspect: CGSize) {
        guard aspect.width > 0, aspect.height > 0 else { return }
        let screen = view.window?.screen ?? NSScreen.main
        // visibleFrame excludes the menu bar / Dock; the ~0.92 leaves the small
        // margin the native preview keeps around the image.
        let bound = (screen?.visibleFrame.size ?? NSSize(width: 1680, height: 1050))
        let target = NSSize(width: bound.width * 0.92, height: bound.height * 0.92)
        let scale = min(target.width / aspect.width, target.height / aspect.height)
        preferredContentSize = NSSize(width: (aspect.width * scale).rounded(),
                                      height: (aspect.height * scale).rounded())
    }

    private func targetPixelSize() -> Int {
        let scale = view.window?.backingScaleFactor ?? 2.0
        let side = max(view.bounds.width, view.bounds.height, 700)
        return min(max(Int((side * scale).rounded()), 512), 2048)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelFullRes()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        fullResTask?.cancel()
    }
}
