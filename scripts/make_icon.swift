// Draws the Label Print app icon. Usage: swift scripts/make_icon.swift <out-1024.png>
import AppKit

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in a top-left origin, like a drawing on paper.
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
func gradient(_ path: CGPath, _ top: UInt32, _ bottom: UInt32) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    let b = path.boundingBox
    ctx.drawLinearGradient(g, start: CGPoint(x: b.midX, y: b.minY), end: CGPoint(x: b.midX, y: b.maxY), options: [])
    ctx.restoreGState()
}
func fill(_ path: CGPath, _ c: CGColor) { ctx.addPath(path); ctx.setFillColor(c); ctx.fillPath() }
func shadowed(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, _ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: color(0x0A1E46, alpha))
    body()
    ctx.restoreGState()
}

// Background tile.
let tile = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 186)
shadowed(24, 10, 0.30) { fill(tile, color(0x2F7BF0)) }
gradient(tile, 0x4D9BFF, 0x1D55CF)

// The roll of labels, peeking out behind the printer.
shadowed(14, 6, 0.20) { fill(rounded(CGRect(x: 322, y: 236, width: 380, height: 150), 30), color(0xF4F7FB)) }
fill(rounded(CGRect(x: 362, y: 276, width: 300, height: 14), 7), color(0xC5D0DE))

// Printer body.
let body = rounded(CGRect(x: 222, y: 330, width: 580, height: 262), 58)
shadowed(30, 16, 0.35) { fill(body, color(0xFFFFFF)) }
gradient(body, 0xFFFFFF, 0xE3E9F2)
fill(rounded(CGRect(x: 276, y: 380, width: 150, height: 24), 12), color(0xC5D0DE))
fill(CGPath(ellipseIn: CGRect(x: 716, y: 374, width: 36, height: 36), transform: nil), color(0x34C759))

// Slot the label comes out of.
fill(rounded(CGRect(x: 292, y: 508, width: 440, height: 40), 20), color(0x16233F))

// The printed label.
let label = CGMutablePath()
label.move(to: CGPoint(x: 342, y: 528))
label.addLine(to: CGPoint(x: 682, y: 528))
label.addLine(to: CGPoint(x: 682, y: 782))
label.addArc(tangent1End: CGPoint(x: 682, y: 812), tangent2End: CGPoint(x: 652, y: 812), radius: 30)
label.addLine(to: CGPoint(x: 372, y: 812))
label.addArc(tangent1End: CGPoint(x: 342, y: 812), tangent2End: CGPoint(x: 342, y: 782), radius: 30)
label.closeSubpath()
shadowed(22, 12, 0.35) { fill(label, color(0xFFFFFF)) }
// A soft shadow where the label leaves the slot.
ctx.saveGState(); ctx.addPath(label); ctx.clip()
let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x16233F, 0.35), color(0x16233F, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fade, start: CGPoint(x: 512, y: 528), end: CGPoint(x: 512, y: 580), options: [])
ctx.restoreGState()

// Barcode and a line of text on the label.
var x: CGFloat = 386
for (i, w) in [14, 8, 22, 8, 14, 30, 8, 14, 8, 22, 14, 8, 30, 14].enumerated() {
    if i % 2 == 0 { fill(CGPath(rect: CGRect(x: x, y: 606, width: CGFloat(w), height: 112), transform: nil), color(0x16233F)) }
    x += CGFloat(w) + 4
}
fill(rounded(CGRect(x: 422, y: 742, width: 180, height: 22), 11), color(0x9AA8BC))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
