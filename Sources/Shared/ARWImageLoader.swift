import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import IOSurface

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
    /// Renders straight into an IOSurface (`CALayer.contents` accepts it and
    /// WindowServer composites it without a copy). sRGB matches the embedded
    /// JPEG's gamut so the two versions compare like-for-like.
    /// Nudge Apple's neutral render toward Sony's in-camera look (what the
    /// embedded JPEG shows): a slight exposure lift plus shadow boost
    /// approximates the camera's tone curve / DRO. Tune to taste.
    static let lookExposure: Float = 0.25
    static let lookShadowBoost: Float = 1.3

    static func fullDecode(url: URL) -> IOSurface? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        filter.exposure = lookExposure
        filter.boostShadowAmount = lookShadowBoost
        guard let output = filter.outputImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let width = Int(output.extent.width), height = Int(output.extent.height)
        guard width > 0, height > 0,
              let surface = IOSurface(properties: [
                  .width: width,
                  .height: height,
                  .bytesPerElement: 4,
                  .pixelFormat: kCVPixelFormatType_32BGRA,
              ]) else { return nil }

        // Move the extent to the origin so it maps onto the surface exactly.
        let image = output.transformed(by: .init(translationX: -output.extent.origin.x,
                                                 y: -output.extent.origin.y))
        ciContext.render(image, to: surface,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: colorSpace)
        return surface
    }

    /// Largest dimension that fits `image` inside `bound`, preserving aspect (never upscaled).
    static func aspectFit(_ image: CGSize, into bound: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return bound }
        let scale = min(bound.width / image.width, bound.height / image.height, 1.0)
        return CGSize(width: (image.width * scale).rounded(),
                      height: (image.height * scale).rounded())
    }
}
