import CoreGraphics
import Foundation

/// Where the camera focused, read from the Sony MakerNote.
///
/// Sony stores the focus location in plain (unencrypted) MakerNote tags:
/// - `0x2027 FocusLocation`  — int16u[4]: image width, height, X, Y.
///   Top-left origin, in the **unrotated** sensor frame. When the camera could
///   not determine a focus location (e.g. manual focus) it writes the image
///   centre as a fallback.
/// - `0x2037 FocusFrameSize` — int16u[3]: frame width, height, valid flag
///   (0x101). Only written by newer bodies; absent → a default-sized box.
///
/// Apple's ImageIO does not parse Sony MakerNotes, so this walks the ARW's
/// TIFF structure directly: IFD0 → Exif IFD (0x8769) → MakerNote (0x927C) →
/// Sony IFD ("SONY DSC" header; entry offsets are absolute file offsets).
struct SonyFocusInfo {

    /// Focus area in the *displayed* (orientation-applied) image, normalized
    /// to 0…1 with a top-left origin.
    let center: CGPoint
    let size: CGSize

    /// Default frame when the file has no FocusFrameSize — matches the spot
    /// AF frame proportions seen on recent bodies (~2 % of the image width).
    private static let defaultFrameFraction: CGFloat = 0.022

    // MARK: - Reading

    static func read(url: URL) -> SonyFocusInfo? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let tiff = TIFFReader(data: data)
        guard let ifd0 = tiff.firstIFD() else { return nil }

        let orientation = tiff.entry(in: ifd0, tag: 0x0112).flatMap { tiff.uint16Values($0).first } ?? 1
        guard let exifEntry = tiff.entry(in: ifd0, tag: 0x8769),
              let exifOffset = tiff.uint32Values(exifEntry).first,
              let makerEntry = tiff.entry(in: Int(exifOffset), tag: 0x927C)
        else { return nil }

        // MakerNote payload: older bodies prefix a 12-byte "SONY DSC"/"SONY CAM"
        // header before the IFD; newer ones (e.g. A7 IV) start the IFD directly.
        // Value offsets inside are absolute (relative to the file start) either way.
        let makerOffset = Int(makerEntry.valueOffset)
        let head = tiff.bytes(at: makerOffset, count: 8)
        let sonyIFD = (head.elementsEqual("SONY DSC".utf8) || head.elementsEqual("SONY CAM".utf8))
            ? makerOffset + 12
            : makerOffset

        guard let locEntry = tiff.entry(in: sonyIFD, tag: 0x2027) else { return nil }
        let loc = tiff.uint16Values(locEntry)
        guard loc.count == 4 else { return nil }
        let (w, h, x, y) = (CGFloat(loc[0]), CGFloat(loc[1]), CGFloat(loc[2]), CGFloat(loc[3]))
        guard w > 0, h > 0 else { return nil } // 0 0 0 0 → panorama / no data

        var frame = CGSize(width: w * defaultFrameFraction, height: w * defaultFrameFraction)
        if let sizeEntry = tiff.entry(in: sonyIFD, tag: 0x2037) {
            let s = tiff.uint16Values(sizeEntry)
            if s.count >= 3, s[2] & 0x1 == 1, s[0] > 0, s[1] > 0 {
                frame = CGSize(width: CGFloat(s[0]), height: CGFloat(s[1]))
            }
        }

        // Normalize in the unrotated frame, then map into display orientation.
        let n = (x: x / w, y: y / h, fw: frame.width / w, fh: frame.height / h)
        switch orientation {
        case 3: // 180°
            return SonyFocusInfo(center: CGPoint(x: 1 - n.x, y: 1 - n.y),
                                 size: CGSize(width: n.fw, height: n.fh))
        case 6: // rotated 90° CW for display
            return SonyFocusInfo(center: CGPoint(x: 1 - n.y, y: n.x),
                                 size: CGSize(width: n.fh, height: n.fw))
        case 8: // rotated 90° CCW for display
            return SonyFocusInfo(center: CGPoint(x: n.y, y: 1 - n.x),
                                 size: CGSize(width: n.fh, height: n.fw))
        default: // 1 (and mirrored variants, which cameras don't write)
            return SonyFocusInfo(center: CGPoint(x: n.x, y: n.y),
                                 size: CGSize(width: n.fw, height: n.fh))
        }
    }
}

/// Minimal, bounds-checked TIFF/IFD walker (read-only, little- or big-endian).
private struct TIFFReader {
    let data: Data

    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        /// Inline value or offset, depending on the payload size.
        let valueOffset: UInt32
        let entryOffset: Int
    }

    private var littleEndian: Bool {
        bytes(at: 0, count: 2).elementsEqual([0x49, 0x49]) // "II"
    }

    func bytes(at offset: Int, count: Int) -> [UInt8] {
        guard offset >= 0, count >= 0, offset + count <= data.count else { return [] }
        return [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + count])
    }

    private static func combine16(_ b: [UInt8], littleEndian: Bool) -> UInt16 {
        let lo: UInt16 = littleEndian ? UInt16(b[0]) : UInt16(b[1])
        let hi: UInt16 = littleEndian ? UInt16(b[1]) : UInt16(b[0])
        return lo | (hi << 8)
    }

    private func uint16(at offset: Int) -> UInt16? {
        let b = bytes(at: offset, count: 2)
        guard b.count == 2 else { return nil }
        return Self.combine16(b, littleEndian: littleEndian)
    }

    private func uint32(at offset: Int) -> UInt32? {
        let b = bytes(at: offset, count: 4)
        guard b.count == 4 else { return nil }
        let ordered: [UInt8] = littleEndian ? b : b.reversed()
        var value: UInt32 = 0
        for (i, byte) in ordered.enumerated() {
            value |= UInt32(byte) << (8 * i)
        }
        return value
    }

    /// Validates the TIFF header and returns the offset of IFD0.
    func firstIFD() -> Int? {
        let order = bytes(at: 0, count: 2)
        guard order.elementsEqual([0x49, 0x49]) || order.elementsEqual([0x4D, 0x4D]),
              uint16(at: 2) == 42,
              let offset = uint32(at: 4)
        else { return nil }
        return Int(offset)
    }

    /// Linear scan of one IFD for a tag (IFDs hold a few dozen entries at most).
    func entry(in ifdOffset: Int, tag: UInt16) -> Entry? {
        guard let count = uint16(at: ifdOffset) else { return nil }
        for i in 0 ..< Int(count) {
            let e = ifdOffset + 2 + i * 12
            guard let t = uint16(at: e) else { return nil }
            if t == tag {
                guard let type = uint16(at: e + 2),
                      let n = uint32(at: e + 4),
                      let value = uint32(at: e + 8) else { return nil }
                return Entry(tag: t, type: type, count: n, valueOffset: value, entryOffset: e)
            }
        }
        return nil
    }

    private static let typeSizes: [UInt16: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 7: 1]

    /// Resolves an entry's payload (inline if ≤ 4 bytes, via offset otherwise).
    private func payload(_ e: Entry) -> [UInt8] {
        let size = (Self.typeSizes[e.type] ?? 1) * Int(e.count)
        return size <= 4 ? bytes(at: e.entryOffset + 8, count: size)
                         : bytes(at: Int(e.valueOffset), count: size)
    }

    /// Payload as 16-bit words — also used for UNDEFINED data (e.g. Sony's
    /// FocusFrameSize is type 7, six bytes, read as three words).
    func uint16Values(_ e: Entry) -> [UInt16] {
        let raw = payload(e)
        guard raw.count >= 2 else { return [] }
        return stride(from: 0, to: raw.count - 1, by: 2).map {
            Self.combine16([raw[$0], raw[$0 + 1]], littleEndian: littleEndian)
        }
    }

    func uint32Values(_ e: Entry) -> [UInt32] {
        if e.type == 3 { return uint16Values(e).map(UInt32.init) }
        var values: [UInt32] = []
        for i in 0 ..< Int(e.count) {
            let off = Int(e.count) * 4 <= 4 ? e.entryOffset + 8 + i * 4 : Int(e.valueOffset) + i * 4
            guard let v = uint32(at: off) else { break }
            values.append(v)
        }
        return values
    }
}
