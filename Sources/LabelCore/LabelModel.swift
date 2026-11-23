import Foundation

public enum ElementKind: String, Codable, CaseIterable {
    case text, qr, barcode, image, box
}

/// One item on a label. Positions and sizes are in printer dots (8 per mm), origin top-left.
public struct LabelElement: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var kind: ElementKind
    /// Top-left of the element's bounding box after rotation.
    public var x: Double = 0
    public var y: Double = 0
    /// Clockwise, one of 0 / 90 / 180 / 270.
    public var rotation = 0

    // text; also the payload of QR codes and barcodes
    public var text = ""
    public var fontName = "Helvetica Neue"
    public var fontSize: Double = 40
    public var bold = false
    public var italic = false
    /// 0 left, 1 centre, 2 right (multi-line text).
    public var alignment = 1

    // qr / barcode / image / box
    public var width: Double = 72
    public var height: Double = 72
    /// Box stroke width; for barcodes, the width of the narrowest bar.
    public var lineWidth: Double = 2
    public var cornerRadius: Double = 0
    public var imageData: Data?
    public var dither = true
    public var invert = false

    public init(kind: ElementKind) { self.kind = kind }
}

public struct LabelDocument: Codable, Equatable {
    /// Across the print head.
    public var widthMM = 12
    /// Along the feed direction.
    public var lengthMM = 40
    public var elements: [LabelElement] = []

    public init() {}

    public var widthDots: Int { widthMM * Wire.dotsPerMM }
    public var lengthDots: Int { lengthMM * Wire.dotsPerMM }

    public static var sample: LabelDocument {
        var d = LabelDocument()
        var qr = LabelElement(kind: .qr)
        qr.text = "https://example.com"; qr.width = 81; qr.x = 14; qr.y = 7
        var t = LabelElement(kind: .text)
        t.text = "Label Print"; t.fontSize = 34; t.bold = true; t.x = 108; t.y = 27
        d.elements = [qr, t]
        return d
    }
}
