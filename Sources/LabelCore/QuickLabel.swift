import AppKit

/// Builds complete labels from a single piece of content, sized to fill the printable area.
public enum QuickLabel {
    public struct Style {
        public var fontName = "Helvetica Neue"
        public var bold = false
        public var italic = false
        /// 0 left, 1 centre, 2 right.
        public var alignment = 1
        /// Clockwise, 0 / 90 / 180 / 270.
        public var rotation = 0
        /// Text height in mm; nil fills the label.
        public var sizeMM: Double?
        public init() {}
    }

    public struct LayoutError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The part of the label the head can reach, with a little breathing room.
    public static func printableRect(_ doc: LabelDocument) -> CGRect {
        let w = Double(doc.lengthDots), h = Double(doc.widthDots)
        let cropped = max(0, (h - Double(Wire.headDots)) / 2)
        let insetX = Double(Wire.marginColumns) + 4, insetY = cropped + 4
        return CGRect(x: insetX, y: insetY, width: max(8, w - 2 * insetX), height: max(8, h - 2 * insetY))
    }

    private static func blank(widthMM: Int, lengthMM: Int) -> LabelDocument {
        var d = LabelDocument()
        d.widthMM = widthMM; d.lengthMM = lengthMM
        return d
    }

    private static func center(_ e: inout LabelElement, in rect: CGRect) {
        let b = Renderer.bounds(e)
        e.x = (rect.minX + (rect.width - b.width) / 2).rounded()
        e.y = (rect.minY + (rect.height - b.height) / 2).rounded()
    }

    /// Largest font size at which the text fits `rect`, then centred in it.
    private static func fit(_ e: inout LabelElement, in rect: CGRect, fixedSize: Double?) {
        if let fixedSize {
            e.fontSize = fixedSize
        } else {
            var lo = 6.0, hi = 400.0
            for _ in 0..<12 {
                let mid = (lo + hi) / 2
                e.fontSize = mid
                let b = Renderer.bounds(e)
                if b.width <= rect.width && b.height <= rect.height { lo = mid } else { hi = mid }
            }
            e.fontSize = lo.rounded(.down)
        }
        center(&e, in: rect)
    }

    private static func textElement(_ string: String, _ style: Style) -> LabelElement {
        var e = LabelElement(kind: .text)
        e.text = string
        e.fontName = style.fontName; e.bold = style.bold; e.italic = style.italic
        e.alignment = style.alignment; e.rotation = style.rotation
        return e
    }

    public static func text(_ string: String, style: Style = Style(), widthMM: Int, lengthMM: Int) -> LabelDocument {
        var doc = blank(widthMM: widthMM, lengthMM: lengthMM)
        var e = textElement(string, style)
        fit(&e, in: printableRect(doc), fixedSize: style.sizeMM.map { $0 * Double(Wire.dotsPerMM) })
        doc.elements = [e]
        return doc
    }

    public static func qr(_ content: String, caption: String? = nil, style: Style = Style(), widthMM: Int, lengthMM: Int) throws -> LabelDocument {
        var doc = blank(widthMM: widthMM, lengthMM: lengthMM)
        let rect = printableRect(doc)
        guard let modules = Renderer.qrImage(content)?.width else { throw LayoutError(message: "Could not make a QR code from that content.") }
        let side = min(rect.width, rect.height)
        guard Double(modules) <= side else {
            throw LayoutError(message: "That is too much content for a QR code on a \(widthMM) mm label.")
        }
        var q = LabelElement(kind: .qr)
        q.text = content; q.width = side
        let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if caption.isEmpty {
            center(&q, in: rect)
            doc.elements = [q]
        } else {
            let qb = Renderer.bounds(q)
            q.x = rect.minX
            q.y = (rect.minY + (rect.height - qb.height) / 2).rounded()
            var t = textElement(caption, style)
            let rest = CGRect(x: rect.minX + qb.width + 8, y: rect.minY, width: rect.width - qb.width - 8, height: rect.height)
            guard rest.width >= 24 else { throw LayoutError(message: "There is no room for a caption next to the QR code.") }
            fit(&t, in: rest, fixedSize: style.sizeMM.map { $0 * Double(Wire.dotsPerMM) })
            doc.elements = [q, t]
        }
        return doc
    }

    public static func barcode(_ content: String, caption: String? = nil, style: Style = Style(), widthMM: Int, lengthMM: Int) throws -> LabelDocument {
        var doc = blank(widthMM: widthMM, lengthMM: lengthMM)
        let rect = printableRect(doc)
        guard let modules = Renderer.barcodeImage(content)?.width else {
            throw LayoutError(message: "Code 128 barcodes take plain ASCII text only.")
        }
        guard let barWidth = [4, 3, 2, 1].first(where: { Double(modules * $0) <= rect.width }) else {
            throw LayoutError(message: "That barcode is too long for a \(lengthMM) mm label. Use a QR code instead.")
        }
        let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let captionHeight = caption.isEmpty ? 0.0 : min(26.0, (rect.height * 0.3).rounded())
        var b = LabelElement(kind: .barcode)
        b.text = content; b.lineWidth = Double(barWidth)
        b.height = rect.height - captionHeight - (caption.isEmpty ? 0 : 2)
        center(&b, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: b.height))
        doc.elements = [b]
        if !caption.isEmpty {
            var t = textElement(caption, style)
            fit(&t, in: CGRect(x: rect.minX, y: rect.maxY - captionHeight, width: rect.width, height: captionHeight), fixedSize: nil)
            doc.elements.append(t)
        }
        return doc
    }

    public static func image(_ data: Data, dither: Bool = true, invert: Bool = false, widthMM: Int, lengthMM: Int) throws -> LabelDocument {
        var doc = blank(widthMM: widthMM, lengthMM: lengthMM)
        let rect = printableRect(doc)
        guard let img = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil), img.width > 0, img.height > 0 else {
            throw LayoutError(message: "That file is not an image this Mac can read.")
        }
        let scale = min(rect.width / Double(img.width), rect.height / Double(img.height))
        var e = LabelElement(kind: .image)
        e.imageData = data; e.dither = dither; e.invert = invert
        e.width = max(2, (Double(img.width) * scale).rounded(.down))
        e.height = max(2, (Double(img.height) * scale).rounded(.down))
        center(&e, in: rect)
        doc.elements = [e]
        return doc
    }
}
