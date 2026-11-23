import AppKit
import CoreImage

/// Turns a label document into the exact 1-bit image the printer will burn.
public enum Renderer {
    public struct Bitmap {
        public var width: Int
        public var height: Int
        /// Row-major, 0 = black, 255 = white. Only those two values after rendering.
        public var pixels: [UInt8]

        public var cgImage: CGImage? {
            guard width > 0, height > 0, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    // MARK: geometry

    /// Size before rotation.
    public static func naturalSize(_ e: LabelElement) -> CGSize {
        switch e.kind {
        case .text:
            let r = attributed(e).boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin])
            return CGSize(width: max(2, ceil(r.width)), height: max(2, ceil(r.height)))
        case .qr:
            guard let img = qrImage(e.text) else { return CGSize(width: max(8, e.width), height: max(8, e.width)) }
            let side = CGFloat(img.width * max(1, Int(e.width) / img.width))
            return CGSize(width: side, height: side)
        case .barcode:
            guard let img = barcodeImage(e.text) else { return CGSize(width: max(8, e.width), height: max(8, e.height)) }
            return CGSize(width: CGFloat(img.width * max(1, Int(e.lineWidth))), height: max(8, e.height))
        case .image, .box:
            return CGSize(width: max(2, e.width.rounded()), height: max(2, e.height.rounded()))
        }
    }

    /// Bounding box on the label, after rotation.
    public static func bounds(_ e: LabelElement) -> CGRect {
        let n = naturalSize(e)
        let swap = e.rotation == 90 || e.rotation == 270
        return CGRect(x: e.x, y: e.y, width: swap ? n.height : n.width, height: swap ? n.width : n.height)
    }

    // MARK: element sources

    /// The exact font a text item is drawn with; `scale` enlarges it for on-screen editing.
    public static func font(for e: LabelElement, scale: CGFloat = 1) -> NSFont {
        var traits: NSFontTraitMask = []
        if e.bold { traits.insert(.boldFontMask) }
        if e.italic { traits.insert(.italicFontMask) }
        let size = max(4, e.fontSize) * scale
        return NSFontManager.shared.font(withFamily: e.fontName, traits: traits, weight: e.bold ? 9 : 5, size: size)
            ?? (e.bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
    }

    /// Size of a text item's block when laid out `scale` times larger, measured rather than multiplied.
    public static func textSize(_ e: LabelElement, scale: CGFloat) -> CGSize {
        var copy = e
        copy.fontSize = max(4, e.fontSize) * scale
        return naturalSize(copy)
    }

    static func attributed(_ e: LabelElement) -> NSAttributedString {
        let font = Self.font(for: e)
        let para = NSMutableParagraphStyle()
        para.alignment = e.alignment == 0 ? .left : (e.alignment == 2 ? .right : .center)
        return NSAttributedString(string: e.text.isEmpty ? " " : e.text,
                                  attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: para])
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: true])
    private static var codeCache: [String: CGImage] = [:]

    private static func generate(_ filterName: String, _ message: String, _ extra: [String: Any]) -> CGImage? {
        guard !message.isEmpty else { return nil }
        let key = filterName + "|" + message
        if let hit = codeCache[key] { return hit }
        guard let filter = CIFilter(name: filterName) else { return nil }
        filter.setValue(message.data(using: filterName == "CICode128BarcodeGenerator" ? .ascii : .utf8), forKey: "inputMessage")
        for (k, v) in extra { filter.setValue(v, forKey: k) }
        guard let out = filter.outputImage, !out.extent.isEmpty,
              let cg = ciContext.createCGImage(out, from: out.extent) else { return nil }
        if codeCache.count > 200 { codeCache.removeAll() }
        codeCache[key] = cg
        return cg
    }

    /// One pixel per module, including the quiet zone.
    static func qrImage(_ text: String) -> CGImage? {
        generate("CIQRCodeGenerator", text, ["inputCorrectionLevel": "M"])
    }

    /// One pixel per narrow bar.
    static func barcodeImage(_ text: String) -> CGImage? {
        guard text.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        return generate("CICode128BarcodeGenerator", text, ["inputQuietSpace": 4])
    }

    // MARK: drawing

    private static func grayContext(_ w: Int, _ h: Int) -> CGContext? {
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                space: CGColorSpaceCreateDeviceGray(),
                                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    private static func pixels(of ctx: CGContext) -> [UInt8] {
        let w = ctx.width, h = ctx.height, stride = ctx.bytesPerRow
        guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h { for x in 0..<w { out[y * w + x] = base[y * stride + x] } }
        return out
    }

    /// Scale a picture to w×h and reduce it to pure black/white.
    private static func prepared(image: CGImage, w: Int, h: Int, dither: Bool, invert: Bool) -> CGImage? {
        guard let ctx = grayContext(w, h) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var px = pixels(of: ctx)
        if invert { for i in px.indices { px[i] = 255 - px[i] } }
        if dither {
            var err = px.map { Float($0) }
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let old = err[i]
                    let new: Float = old < 128 ? 0 : 255
                    px[i] = UInt8(new)
                    let e = old - new
                    if x + 1 < w { err[i + 1] += e * 7 / 16 }
                    if y + 1 < h {
                        if x > 0 { err[i + w - 1] += e * 3 / 16 }
                        err[i + w] += e * 5 / 16
                        if x + 1 < w { err[i + w + 1] += e / 16 }
                    }
                }
            }
        } else {
            for i in px.indices { px[i] = px[i] < 128 ? 0 : 255 }
        }
        return Bitmap(width: w, height: h, pixels: px).cgImage
    }

    /// Draw a CGImage upright into a y-down context.
    private static func drawUpright(_ img: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func drawPlaceholder(_ rect: CGRect, _ ctx: CGContext) {
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.move(to: rect.origin); ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.move(to: CGPoint(x: rect.maxX, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.strokePath()
    }

    private static func draw(_ e: LabelElement, _ ctx: CGContext) {
        let n = naturalSize(e)
        let b = bounds(e)
        ctx.saveGState()
        ctx.translateBy(x: b.minX.rounded() + b.width / 2, y: b.minY.rounded() + b.height / 2)
        ctx.rotate(by: CGFloat(e.rotation) * .pi / 180)
        ctx.translateBy(x: -n.width / 2, y: -n.height / 2)
        let rect = CGRect(origin: .zero, size: n)
        switch e.kind {
        case .text:
            attributed(e).draw(with: rect, options: [.usesLineFragmentOrigin])
        case .qr:
            if let img = qrImage(e.text) { drawUpright(img, in: rect, ctx) } else { drawPlaceholder(rect, ctx) }
        case .barcode:
            if let img = barcodeImage(e.text) { drawUpright(img, in: rect, ctx) } else { drawPlaceholder(rect, ctx) }
        case .image:
            if let data = e.imageData, let src = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let img = prepared(image: src, w: Int(n.width), h: Int(n.height), dither: e.dither, invert: e.invert) {
                drawUpright(img, in: rect, ctx)
            } else {
                drawPlaceholder(rect, ctx)
            }
        case .box:
            let lw = max(1, e.lineWidth.rounded())
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.setLineWidth(lw)
            let r = rect.insetBy(dx: lw / 2, dy: lw / 2)
            let radius = max(0, min(e.cornerRadius, min(r.width, r.height) / 2))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// The whole label as a black/white bitmap, `lengthDots` wide and `widthDots` tall.
    public static func render(_ doc: LabelDocument) -> Bitmap {
        let w = max(8, doc.lengthDots), h = max(8, doc.widthDots)
        guard let ctx = grayContext(w, h) else { return Bitmap(width: w, height: h, pixels: [UInt8](repeating: 255, count: w * h)) }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldSmoothFonts(false)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for e in doc.elements { draw(e, ctx) }
        NSGraphicsContext.current = previous
        var px = pixels(of: ctx)
        for i in px.indices { px[i] = px[i] < 128 ? 0 : 255 }
        return Bitmap(width: w, height: h, pixels: px)
    }

    /// A smooth, anti-aliased picture of the label for the screen, `scale` pixels per printer dot.
    /// Easier on the eye than the dots, but only `render` shows exactly what will be burned.
    public static func preview(_ doc: LabelDocument, scale: CGFloat) -> CGImage? {
        let w = max(8, doc.lengthDots), h = max(8, doc.widthDots)
        let s = max(1, min(scale, 16))
        guard let ctx = grayContext(Int((CGFloat(w) * s).rounded()), Int((CGFloat(h) * s).rounded())) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: CGFloat(ctx.width) / CGFloat(w), y: -CGFloat(ctx.height) / CGFloat(h))
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for e in doc.elements { draw(e, ctx) }
        NSGraphicsContext.current = previous
        return ctx.makeImage()
    }

    /// Printable head columns for the printer: 12 bytes per column, the label's end margins left out.
    public static func columns(_ doc: LabelDocument) -> [[UInt8]] {
        let bmp = render(doc)
        let head = Wire.headDots
        let yOffset = (head - bmp.height) / 2          // negative when the label is wider than the head
        let m = Wire.marginColumns
        guard bmp.width > 2 * m else { return [] }
        return (m..<(bmp.width - m)).map { x in
            var col = [UInt8](repeating: 0, count: Wire.bytesPerColumn)
            for dot in 0..<head {
                let y = dot - yOffset
                if y >= 0, y < bmp.height, bmp.pixels[y * bmp.width + x] == 0 { col[dot >> 3] |= UInt8(1 << (dot & 7)) }
            }
            return col
        }
    }

    public static func pngData(_ bmp: Bitmap, scale: Int = 1) -> Data? {
        guard let cg = bmp.cgImage else { return nil }
        let w = bmp.width * scale, h = bmp.height * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}
