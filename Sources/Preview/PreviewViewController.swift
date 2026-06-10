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
    /// Autofocus frame outline, drawn on top of both image layers.
    private let focusLayer = CALayer()
    private var focusInfo: SonyFocusInfo?
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
            focusLayer.isHidden = true
        }
    }

    // MARK: - Focus point overlay

    func setFocus(_ info: SonyFocusInfo?, visible: Bool) {
        focusInfo = info
        withoutAnimation {
            focusLayer.isHidden = !(visible && info != nil)
            layoutFocusLayer()
        }
    }

    func setFocusVisible(_ visible: Bool) {
        withoutAnimation { focusLayer.isHidden = !(visible && focusInfo != nil) }
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
        focusLayer.frame = CGRect(x: info.center.x * bounds.width - w / 2,
                                  y: (1 - info.center.y) * bounds.height - h / 2,
                                  width: w, height: h)
        focusLayer.borderWidth = 2 / focusScale
        focusLayer.cornerRadius = 3 / focusScale
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
    private let spinner = NSProgressIndicator()
    /// Single status chip, always bottom-left: "Preview" / "Loading…" / "Full".
    private let statusButton = NSButton()
    /// Toggles the autofocus-point overlay; hidden when the file has no AF data.
    private let afButton = NSButton()
    private static let decoder = FullResDecoder()

    private var currentURL: URL?
    private var fullResTask: Task<Void, Never>?
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

        configureStatusButton(); root.addSubview(statusButton)
        configureAFButton(); root.addSubview(afButton)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            statusButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            statusButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            afButton.leadingAnchor.constraint(equalTo: statusButton.trailingAnchor, constant: 8),
            afButton.centerYAnchor.constraint(equalTo: statusButton.centerYAnchor),

            spinner.leadingAnchor.constraint(equalTo: afButton.trailingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: statusButton.centerYAnchor),
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

    private func configureStatusButton() {
        statusButton.bezelStyle = .badge
        statusButton.controlSize = .small
        statusButton.font = .systemFont(ofSize: 10, weight: .semibold)
        statusButton.target = self
        statusButton.action = #selector(chipClicked)
        statusButton.translatesAutoresizingMaskIntoConstraints = false
        setState(.preview)
    }

    private func configureAFButton() {
        afButton.bezelStyle = .badge
        afButton.controlSize = .small
        afButton.font = .systemFont(ofSize: 10, weight: .semibold)
        afButton.title = "AF"
        afButton.target = self
        afButton.action = #selector(afClicked)
        afButton.isHidden = true
        afButton.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Reflect the overlay state in the chip (dimmed = overlay off).
    private func updateAFButton() {
        afButton.isHidden = focusInfo == nil
        afButton.alphaValue = showFocus ? 1.0 : 0.45
        afButton.toolTip = showFocus ? "Hide focus point" : "Show focus point"
    }

    @objc private func afClicked() {
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
            statusButton.title = "Loading…"
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
        if url == currentURL, hasEmbedded { return }

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
            canvas.setFocus(focus, visible: showFocus)
            updateAFButton()
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
        fullResTask = Task { [weak self] in
            await self?.runFullDecode(url: url)
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

    private func runFullDecode(url: URL) async {
        spinner.startAnimation(nil)
        setState(.loading)

        // Serialized through the actor; throws (returns nil) if this task was
        // cancelled while waiting its turn or before the render started.
        let full = try? await Self.decoder.decode(url: url)

        spinner.stopAnimation(nil)
        guard !Task.isCancelled, currentURL == url else { return }
        fullResTask = nil
        if let full {
            hasFull = true
            attachFull(full)
            setState(.full)
        } else {
            setState(.preview)
        }
    }

    private func cancelFullRes() {
        fullResTask?.cancel()
        fullResTask = nil
    }

    // MARK: - Helpers

    private func detachedDecode(_ work: @escaping () -> CGImage?) async -> CGImage? {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    private func setPreferredSize(aspect: CGSize) {
        guard aspect.width > 0, aspect.height > 0 else { return }
        let fitted = ARWImageLoader.aspectFit(aspect, into: NSSize(width: 1400, height: 1000))
        preferredContentSize = fitted
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
