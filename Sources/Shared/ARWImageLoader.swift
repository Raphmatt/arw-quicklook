import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Two-tier ARW loader.
///
/// `embeddedPreview` lifts the camera's baked-in JPEG preview (~1616 px on most
/// Sony bodies) via ImageIO — no Bayer/raw development. Measured ~20 ms warm.
///
/// `fullDecode` runs a real raw development through Core Image's `CIRAWFilter`
/// at native resolution — used only on demand / in the background. ~130 ms once
/// the GPU pipeline is warm (first call in a process is slower, Metal warm-up).
enum ARWImageLoader {

    /// Shared GPU context so repeated full decodes reuse the compiled pipeline.
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Fast path: the embedded preview. Falls back to a raw decode only if the
    /// file genuinely has no embedded preview (rare for Sony).
    static func embeddedPreview(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            // Use the embedded preview when present; decode the raw ONLY if absent.
            // (Never set kCGImageSourceCreateThumbnailFromImageAlways — that forces a full decode.)
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Slow path: full-resolution raw development. Call off the main thread.
    ///
    /// `deferred: false` is load-bearing: the default `createCGImage` can return
    /// a lazily-rendered CGImage whose actual RAW development runs later, on the
    /// main thread, when the image is first drawn — freezing the UI at swap time.
    static func fullDecode(url: URL) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url),
              let output = filter.outputImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        return ciContext.createCGImage(output, from: output.extent,
                                       format: .RGBA8, colorSpace: colorSpace,
                                       deferred: false)
    }

    /// Largest dimension that fits `image` inside `bound`, preserving aspect (never upscaled).
    static func aspectFit(_ image: CGSize, into bound: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return bound }
        let scale = min(bound.width / image.width, bound.height / image.height, 1.0)
        return CGSize(width: (image.width * scale).rounded(),
                      height: (image.height * scale).rounded())
    }
}
