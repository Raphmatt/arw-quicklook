import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import IOSurface

/// Two-tier ARW loader.
///
/// `embeddedPreview` lifts the camera's small baked-in JPEG preview (~1616 px)
/// via ImageIO — no Bayer/raw development. Measured ~20 ms warm.
///
/// `fullDecode` produces the full-resolution image. Newer Sony bodies (e.g. the
/// A7 IV) store a full-size camera JPEG in IFD2 (`JpgFromRaw`) that ImageIO's
/// thumbnail API never returns; decoding it takes ~60 ms and matches the
/// camera's look exactly (Creative Look, DRO, lens corrections). Files without
/// one fall back to a real raw development through `CIRAWFilter` (~560 ms warm).
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

    // MARK: - Full resolution

    /// Slow path: the full-resolution image, rendered into an IOSurface
    /// (`CALayer.contents` accepts it and WindowServer composites it without a
    /// copy). Call off the main thread. Tries the full-size embedded camera JPEG
    /// first and develops the raw only when there is none.
    static func fullDecode(url: URL) -> IOSurface? {
        if let jpeg = fullSizeEmbeddedJPEG(url: url) {
            return render(jpeg)
        }
        // The raw development is the expensive part: skip it if the caller
        // moved on while the JPEG lookup ran.
        if Task.isCancelled { return nil }
        return rawDecode(url: url)
    }

    /// Nudge Apple's neutral raw render toward Sony's in-camera look (only used
    /// by the CIRAWFilter fallback): a slight exposure lift plus shadow boost
    /// approximates the camera's tone curve / DRO. Tune to taste.
    static let lookExposure: Float = 0.25
    static let lookShadowBoost: Float = 1.3

    /// Raw development through Core Image (GPU), for files without a full-size
    /// embedded JPEG (older bodies).
    static func rawDecode(url: URL) -> IOSurface? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        filter.exposure = lookExposure
        filter.boostShadowAmount = lookShadowBoost
        guard let output = filter.outputImage else { return nil }
        return render(output)
    }

    /// Renders `image` into a BGRA IOSurface in sRGB, the embedded preview's
    /// gamut, so the preview and the full image compare like-for-like.
    private static func render(_ image: CIImage) -> IOSurface? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0,
              let surface = IOSurface(properties: [
                  .width: width,
                  .height: height,
                  .bytesPerElement: 4,
                  .pixelFormat: kCVPixelFormatType_32BGRA,
              ]) else { return nil }

        // Move the extent to the origin so it maps onto the surface exactly.
        let origin = image.transformed(by: .init(translationX: -image.extent.origin.x,
                                                 y: -image.extent.origin.y))
        ciContext.render(origin, to: surface,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: colorSpace)
        return surface
    }

    // MARK: - Full-size embedded JPEG

    /// The small preview Sony embeds in every ARW; a JPEG must be larger than
    /// this to count as full size (M/S raw sizes still qualify).
    static let previewLongEdge = 1616
    /// Sanity cap on the JPEG's long edge (largest Sony sensors are ~9.6k px).
    static let maxLongEdge = 16384
    /// IFDs walked in the main chain (A7 IV: IFD0 preview, IFD1 thumbnail,
    /// IFD2 full-size JPEG); also guards against a crafted cyclic chain.
    private static let maxIFDs = 8

    /// The camera's full-size JPEG as a CIImage, oriented for display and tagged
    /// with the colour space the ARW states. Nil when the file has none.
    static func fullSizeEmbeddedJPEG(url: URL) -> CIImage? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let tiff = TIFFReader(data: data)
        guard let ifd0 = tiff.firstIFD(),
              let jpeg = largestJPEG(in: tiff),
              let header = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(header, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              max(w, h) > previewLongEdge, max(w, h) <= maxLongEdge, min(w, h) > 0
        else { return nil }

        // The JPEG carries no EXIF/ICC of its own: colour space and orientation
        // come from the enclosing ARW.
        guard let image = CIImage(data: jpeg, options: [
            .colorSpace: colorSpace(tiff: tiff, ifd0: ifd0),
            .applyOrientationProperty: false,
        ]) else { return nil }

        let raw = tiff.entry(in: ifd0, tag: 0x0112).flatMap { tiff.uint16Values($0).first } ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(raw)) ?? .up
        return image.oriented(orientation)
    }

    /// Bytes of the largest JPEG referenced by `JPEGInterchangeFormat`
    /// (0x0201/0x0202) in the main IFD chain, if it starts with an SOI marker.
    private static func largestJPEG(in tiff: TIFFReader) -> Data? {
        var best: Range<Int>?
        var ifd = tiff.firstIFD()
        var seen = Set<Int>()
        while let offset = ifd, seen.count < maxIFDs, seen.insert(offset).inserted {
            if let startEntry = tiff.entry(in: offset, tag: 0x0201),
               let lengthEntry = tiff.entry(in: offset, tag: 0x0202),
               let start = tiff.uint32Values(startEntry).first.map(Int.init),
               let length = tiff.uint32Values(lengthEntry).first.map(Int.init),
               length > 2, start <= tiff.data.count - length, // no overflow: both ≥ 0
               length > (best?.count ?? 0) {
                best = start ..< start + length
            }
            ifd = tiff.nextIFD(after: offset)
        }
        guard let range = best else { return nil }
        let base = tiff.data.startIndex
        let bytes = tiff.data.subdata(in: base + range.lowerBound ..< base + range.upperBound)
        guard bytes.starts(with: [0xFF, 0xD8]) else { return nil }
        return bytes
    }

    /// Colour space of the embedded JPEG per the ARW's Exif: ColorSpace (0xA001)
    /// 1 = sRGB; 0xFFFF (Uncalibrated) with InteropIndex "R03" = Adobe RGB (the
    /// DCF option file, as a Sony body shot in Adobe RGB writes). sRGB otherwise.
    private static func colorSpace(tiff: TIFFReader, ifd0: Int) -> CGColorSpace {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let exifEntry = tiff.entry(in: ifd0, tag: 0x8769),
              let exif = tiff.uint32Values(exifEntry).first.map(Int.init),
              let spaceEntry = tiff.entry(in: exif, tag: 0xA001),
              tiff.uint16Values(spaceEntry).first == 0xFFFF,
              let interopEntry = tiff.entry(in: exif, tag: 0xA005),
              let interop = tiff.uint32Values(interopEntry).first.map(Int.init),
              let indexEntry = tiff.entry(in: interop, tag: 0x0001),
              tiff.payload(indexEntry).starts(with: Array("R03".utf8)),
              let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998)
        else { return srgb }
        return adobe
    }

    /// Largest dimension that fits `image` inside `bound`, preserving aspect (never upscaled).
    static func aspectFit(_ image: CGSize, into bound: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return bound }
        let scale = min(bound.width / image.width, bound.height / image.height, 1.0)
        return CGSize(width: (image.width * scale).rounded(),
                      height: (image.height * scale).rounded())
    }
}
