import CoreGraphics
import QuickLookThumbnailing

/// Finder / icon thumbnails — always the fast embedded-preview path.
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let maxPixel = Int(max(request.maximumSize.width, request.maximumSize.height) * request.scale)
        guard let cg = ARWImageLoader.embeddedPreview(url: request.fileURL,
                                                       maxPixelSize: max(maxPixel, 64)) else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }

        // Context size (points) keeps the image's aspect ratio inside the icon
        // slot. Draw into the context's own *pixel* dimensions (ctx.width/height)
        // rather than a point-sized rect — otherwise on a Retina display the
        // image only fills the bottom-left 1/scale² of the backing store.
        let drawn = ARWImageLoader.aspectFit(CGSize(width: cg.width, height: cg.height),
                                             into: request.maximumSize)
        let reply = QLThumbnailReply(contextSize: drawn) { (ctx: CGContext) -> Bool in
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            return true
        }
        handler(reply, nil)
    }
}
