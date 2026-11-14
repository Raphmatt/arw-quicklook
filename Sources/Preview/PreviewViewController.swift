import Cocoa
import IOSurface
import Quartz // QLPreviewingController
import os

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

/// Serializes full-image renders so at most one runs at a time. A queued render
/// whose task was cancelled while waiting (another image, or a sharper render
/// was requested) bails out before doing any work.
actor FullResDecoder {
    func render(_ source: ARWImageLoader.FullSource, scale: CGFloat) throws -> IOSurface? {
        try Task.checkCancellation()
        return ARWImageLoader.render(source, scale: scale)
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
    /// The canvas lives in the embedded preview's pixel coordinates and is scaled by the scroll
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

    /// Installs (or upgrades) the full image. Any resolution: the layer
    /// stretches it to the canvas, which keeps fixed coordinates.
    func setFull(_ surface: IOSurface) {
        withoutAnimation { fullLayer.contents = surface }
    }

    /// Drops the full image (frees its surface) and shows the embedded one.
    func clearFull() {
        withoutAnimation {
            fullLayer.contents = nil
            fullLayer.zPosition = 0
            embeddedLayer.zPosition = 1
        }
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
/// - The full image is rendered in the background at the resolution the panel
///   shows (sharper renders on zoom-in or resize, released on close) and swaps
///   in without changing the framing. Moving to another image cancels it.
/// - Bottom-left icon buttons (embedded/full, AF overlay) appear only when the
///   pointer moves; nothing there changes while flipping through images.
/// - Pinch / double-tap to zoom, free two-finger panning — like Preview.app.
final class PreviewViewController: NSViewController, QLPreviewingController {

    private let scrollView = NSScrollView()
    private let canvas = ImageCanvasView()
    /// Bottom-left icon buttons (embedded/full, AF overlay); hidden until the
    /// pointer moves. No loading indicator — it flickered on every image.
    private let controls = ControlsCapsule()
    private static let decoder = FullResDecoder()

    private static let log = Logger(subsystem: "io.github.raphmatt.arwquicklook", category: "render")

    /// Re-render only when the screen needs >10 % more pixels than rendered…
    private static let upscaleTolerance: CGFloat = 1.1
    /// …then render 30 % beyond the need, so a pinch doesn't render every step…
    private static let zoomHeadroom: CGFloat = 1.3
    /// …and go straight to native resolution once that close to it.
    private static let snapToNative: CGFloat = 0.85

    private var currentURL: URL?
    /// The current file's full-resolution source (compressed, cheap to keep).
    private var source: ARWImageLoader.FullSource?
    private var fullResTask: Task<Void, Never>?
    private var resolutionCheck: Task<Void, Never>?
    /// Bumped per file and when the preview closes; renders from an older
    /// generation are dropped.
    private var fileGeneration = 0
    /// Scale (fraction of native pixels) of the installed / requested render.
    private var renderedScale: CGFloat = 0
    private var pendingScale: CGFloat = 0
    private var inLiveMagnify = false
    /// Between prepare and viewWillDisappear; no renders outside it.
    private var isVisible = false
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
        let root = PreviewRootView(frame: NSRect(x: 0, y: 0, width: 1000, height: 680))
        root.wantsLayer = true
        root.controls = controls

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

        controls.layersButton.target = self
        controls.layersButton.action = #selector(layersClicked)
        controls.afButton.target = self
        controls.afButton.action = #selector(afClicked)
        root.addSubview(controls)
        setState(.preview)
        updateAFButton()

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyStarted),
            name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyEnded),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(backingChanged(_:)),
            name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
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

    /// AF button: brightness = overlay on/off; dim when there's nothing to
    /// show (no AF data, or manual focus). Mode details go to the tooltip.
    private func updateAFButton() {
        let available = focusInfo.map { !$0.isManualFocus } ?? false
        let parts: [String?] = [focusInfo?.focusMode, focusInfo?.areaMode, focusInfo?.tracking]
        var details = parts.compactMap { $0 }.joined(separator: " · ")
        if focusInfo == nil { details = "No focus data in this file" }
        if focusInfo?.isManualFocus == true { details += " — no focus point recorded" }
        controls.setAF(on: showFocus, available: available, details: details)
    }

    @objc private func afClicked() {
        // The toggle-type button flips its own state before this runs; always
        // write the real state back, also when the click is a no-op.
        defer { updateAFButton() }
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
        scheduleResolutionCheck() // zoom by double-tap / programmatic changes
    }

    /// What's on screen, mirrored in the layers button's brightness only.
    /// Loading counts as "full" visually: it arrives within milliseconds, and
    /// dimming in between would flash the button on every image.
    private func setState(_ state: LoadState) {
        self.state = state
        controls.setLayers(showingFull: state != .preview, available: hasFull || state == .loading,
                           loading: state == .loading)
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
        // Quick Look may re-prepare the same file (e.g. window state changes).
        // Keep what is loaded. If the panel was closed meanwhile (which
        // released the full image), render it again at the size now needed.
        // (Without an embedded preview and without a render, nothing is shown:
        // start over, so an unreadable file throws again.)
        isVisible = true
        if url == currentURL, hasEmbedded || hasFull {
            if !hasFull, fullResTask == nil { updateResolution() }
            return
        }

        releaseFull()
        setState(.loading) // straight on, so the button doesn't dim between files
        currentURL = url
        isFitted = true
        hasEmbedded = false
        source = nil
        focusInfo = nil
        canvas.reset()
        // The AF button keeps its look until this file's focus data is read.

        let px = targetPixelSize()
        async let focusTask = Task.detached(priority: .userInitiated) {
            SonyFocusInfo.read(url: url)
        }.value
        async let sourceTask = Task.detached(priority: .userInitiated) {
            ARWImageLoader.openSource(url: url)
        }.value

        // The canvas keeps the embedded preview's coordinates for the whole
        // life of the file: renders of any resolution stretch into the same
        // frame, so a sharper image never moves the framing.
        if let preview = await detachedDecode({ ARWImageLoader.embeddedPreview(url: url, maxPixelSize: px) }),
           currentURL == url {
            hasEmbedded = true
            setCanvasSize(CGSize(width: preview.width, height: preview.height))
            canvas.setEmbedded(preview)
        }

        let opened = await sourceTask
        guard currentURL == url else { return } // superseded while awaiting
        source = opened
        if !hasEmbedded, let opened { setCanvasSize(opened.nativeSize) }

        if let focus = await focusTask, currentURL == url {
            focusInfo = focus
            showFocus = SharedSettings.showFocusPoint
            canvas.setFocus(focus, visible: showFocus, showZones: SharedSettings.showFocusZones)
        }
        guard currentURL == url else { return }
        updateAFButton()

        // Nothing to show yet (no embedded preview): wait for the first render
        // here, so a file that can't be read at all throws and Quick Look
        // shows its generic fallback instead of an empty panel.
        if !hasEmbedded {
            updateResolution()
            // A later resolution check may replace the task; wait for whichever
            // is current until a render landed or none is left.
            while currentURL == url, !hasFull, let task = fullResTask { await task.value }
            if currentURL == url, !hasFull { throw CocoaError(.fileReadCorruptFile) }
            return
        }

        // The sharp image starts right away — only rapid flipping stays on the
        // embedded preview, because moving to another file cancels the render.
        updateResolution()
    }

    // MARK: - Display

    private func setCanvasSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        setPreferredSize(aspect: size)
        canvas.frame = NSRect(origin: .zero, size: size)
        fitAndCenter()
    }

    /// Magnification that fits `imageSize` into `container` (the scroll view's
    /// current bounds by default).
    private func fitMagnification(for imageSize: NSSize, in container: NSSize? = nil) -> CGFloat {
        let b = container ?? scrollView.bounds.size
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
        scheduleResolutionCheck() // a bigger panel may need more pixels
    }

    @objc private func liveMagnifyStarted() {
        isFitted = false
        inLiveMagnify = true
    }

    @objc private func liveMagnifyEnded() {
        inLiveMagnify = false
        updateResolution()
    }

    @objc private func userInteracted() { isFitted = false }

    @objc private func backingChanged(_ note: Notification) {
        guard (note.object as? NSWindow) === view.window else { return }
        updateResolution() // moved to a display with a different pixel density
    }

    // MARK: - Display-resolution rendering

    /// Fraction of the source's native pixels the screen needs right now:
    /// device pixels per canvas point (magnification × backing scale) divided
    /// by source pixels per canvas point.
    private func neededScale() -> CGFloat? {
        guard let source, source.nativeSize.width > 0, canvas.frame.width > 0 else { return nil }
        let backing = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var magnification = scrollView.magnification
        if isFitted {
            // Before Quick Look's first resize the bounds are still the
            // placeholder size — size the first render for the panel it asked for.
            let panel = NSSize(width: max(scrollView.bounds.width, preferredContentSize.width),
                               height: max(scrollView.bounds.height, preferredContentSize.height))
            magnification = max(magnification, fitMagnification(for: canvas.frame.size, in: panel))
        }
        return min(1, magnification * backing * canvas.frame.width / source.nativeSize.width)
    }

    /// Renders a sharper image when the current one would be upscaled on
    /// screen. Never downgrades while visible (zooming back out keeps the
    /// sharper surface); `releaseFull()` frees it when the preview closes.
    private func updateResolution() {
        // Never render while closed: layout or backing changes can still
        // arrive after viewWillDisappear.
        guard isVisible, let url = currentURL, let source, let needed = neededScale() else { return }
        let have = max(renderedScale, pendingScale)
        guard needed > have * Self.upscaleTolerance else { return }

        // First render: exactly what the fitted panel shows. Later ones: with
        // headroom, so a pinch doesn't trigger a render per step; close to
        // native it's not worth a partial render.
        var target = have == 0 ? needed : needed * Self.zoomHeadroom
        if target >= Self.snapToNative { target = 1 }

        // A queued render that's now too small bails before it starts; one
        // already running finishes and is still used if it is an upgrade.
        fullResTask?.cancel()
        pendingScale = target
        let generation = fileGeneration
        if !hasFull { setState(.loading) }
        fullResTask = Task { [weak self] in
            let started = Date()
            let surface = try? await Self.decoder.render(source, scale: target)
            self?.installRender(surface, scale: target, url: url,
                                generation: generation, started: started)
        }
    }

    /// Trailing 150 ms debounce while the user scrolls or resizes.
    private func scheduleResolutionCheck() {
        guard !inLiveMagnify, source != nil else { return }
        resolutionCheck?.cancel()
        resolutionCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.updateResolution()
        }
    }

    private func installRender(_ surface: IOSurface?, scale: CGFloat, url: URL,
                               generation: Int, started: Date) {
        // A render for another file, or from before the preview closed.
        guard generation == fileGeneration, currentURL == url else { return }
        if scale == pendingScale { // the latest request has finished
            pendingScale = 0
            fullResTask = nil
        }
        guard let surface else {
            if !hasFull, pendingScale == 0 { setState(.preview) } // render failed: dim
            return
        }
        guard scale > renderedScale else { return } // a newer, sharper one won
        Self.log.debug("""
            render scale \(scale, format: .fixed(precision: 2)) → \(surface.width)×\(surface.height) \
            in \(Int(-started.timeIntervalSinceNow * 1000)) ms
            """)
        renderedScale = scale
        canvas.setFull(surface) // same frame, so no framing math
        if !hasFull {
            hasFull = true
            canvas.showFull(true)
            setState(.full)
        }
    }

    /// Frees the big surface and stops pending renders (new file, or the
    /// preview closed). The small embedded preview and the opened source stay;
    /// a re-prepare renders again at the size then needed.
    private func releaseFull() {
        fullResTask?.cancel()
        fullResTask = nil
        resolutionCheck?.cancel()
        resolutionCheck = nil
        fileGeneration &+= 1
        renderedScale = 0
        pendingScale = 0
        if hasFull {
            hasFull = false
            canvas.clearFull()
            ARWImageLoader.ciContext.clearCaches()
        }
        setState(.preview)
    }

    /// Toggle between the cached embedded and full-resolution versions.
    @objc private func layersClicked() {
        // The toggle-type button flips its own state before this runs; always
        // write the real state back, also when the click is a no-op.
        defer { setState(state) }
        switch state {
        case .loading:
            return // render already running; swallow the click
        case .full:
            guard hasEmbedded else { return }
            canvas.showFull(false)
            setState(.preview)
        case .preview:
            if hasFull {
                canvas.showFull(true)
                setState(.full)
            } else if fullResTask == nil {
                updateResolution()
            }
        }
    }

    // MARK: - Helpers

    private func detachedDecode(_ work: @escaping @Sendable () -> CGImage?) async -> CGImage? {
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
        isVisible = false
        inLiveMagnify = false // the end-of-pinch notification may never come
        controls.resetHover()
        releaseFull() // don't hold a screen-sized (or larger) surface while closed
    }
}
