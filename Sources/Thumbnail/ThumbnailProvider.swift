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

        let drawn = ARWImageLoader.aspectFit(CGSize(width: cg.width, height: cg.height),
                                             into: request.maximumSize)
        let reply = QLThumbnailReply(contextSize: drawn) { (ctx: CGContext) -> Bool in
            ctx.draw(cg, in: CGRect(origin: .zero, size: drawn))
            return true
        }
        handler(reply, nil)
    }
}
