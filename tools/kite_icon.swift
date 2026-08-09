import AppKit
import CoreGraphics

// Everything is authored on the 1024pt macOS icon grid and scaled per output size,
// so each PNG is rendered from the vector rather than resampled from a big one.
let grid: CGFloat = 1024

func kitePath() -> CGPath {
    // A short span above the crossbar and a long point below it is what separates a kite
    // from a plain diamond, so the proportions are deliberately lopsided.
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 512, y: 846))    // top
    p.addLine(to: CGPoint(x: 294, y: 630)) // left
    p.addLine(to: CGPoint(x: 512, y: 198)) // bottom
    p.addLine(to: CGPoint(x: 730, y: 630)) // right
    p.closeSubpath()
    return p
}

func draw(into ctx: CGContext, size: CGFloat) {
    let scale = size / grid
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    ctx.setLineJoin(.round)

    let space = CGColorSpaceCreateDeviceRGB()

    // Same construction as Telegram's macOS icon — a light squircle plate, a saturated disc
    // inset within it, and a white glyph on the disc — so Kite reads as the same kind of app
    // in the Dock. The hue stays indigo rather than Telegram's cyan so the two never blur
    // together at a glance.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let plateGradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
            CGColor(red: 0.925, green: 0.925, blue: 0.945, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(plateGradient,
                           start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100),
                           options: [])
    ctx.restoreGState()

    // A hairline keeps the white plate from dissolving into a light desktop or Finder list.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.setStrokeColor(CGColor(red: 0.72, green: 0.72, blue: 0.76, alpha: 0.55))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    let discRadius: CGFloat = 305
    let centre = CGPoint(x: 512, y: 512)
    let disc = CGRect(x: centre.x - discRadius, y: centre.y - discRadius,
                      width: discRadius * 2, height: discRadius * 2)

    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    let discGradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.518, green: 0.451, blue: 1.000, alpha: 1),
            CGColor(red: 0.267, green: 0.176, blue: 0.784, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    // Diagonal, matching how Telegram lights its disc from the top-left.
    ctx.drawLinearGradient(discGradient,
                           start: CGPoint(x: centre.x - discRadius, y: centre.y + discRadius),
                           end: CGPoint(x: centre.x + discRadius, y: centre.y - discRadius),
                           options: [])
    ctx.restoreGState()

    // The kite is authored around (512, 522); recentre it on the disc and shrink it to sit
    // inside with a margin comparable to Telegram's plane.
    var transform = CGAffineTransform.identity
        .translatedBy(x: centre.x, y: centre.y)
        .scaledBy(x: 0.70, y: 0.70)
        .translatedBy(x: -512, y: -522)
    let kite = kitePath().copy(using: &transform)!

    // Filling and stroking the same path with a round join rounds the four corners,
    // which keeps the silhouette from looking sharp and dated at large sizes.
    let corner: CGFloat = 34

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8),
                  blur: 22,
                  color: CGColor(red: 0.08, green: 0.03, blue: 0.30, alpha: 0.30))
    // Fill and stroke each cast their own shadow, and the stroke's would land on top of the
    // fill as a dark inner edge. Compositing both in one transparency layer casts a single
    // shadow behind the finished shape instead.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(kite)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(corner)
    ctx.drawPath(using: .fillStroke)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Left half in a cooler tint reads as the fold in a piece of folded paper, the same trick
    // Telegram's plane uses to suggest a crease.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: centre.x, height: grid))
    ctx.addPath(kite)
    let fold = CGColor(red: 0.792, green: 0.776, blue: 0.965, alpha: 1)
    ctx.setFillColor(fold)
    ctx.setStrokeColor(fold)
    ctx.setLineWidth(corner)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    ctx.restoreGState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    draw(into: gctx.cgContext, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
// Filenames mirror what Contents.json already references; several sizes appear twice
// because the catalog lists both the 1x and 2x slot that resolve to the same pixels.
let files: [(String, Int)] = [
    ("Logo_16.png", 16), ("Logo_32.png", 32), ("Logo_32-1.png", 32),
    ("Logo_64.png", 64), ("Logo_128.png", 128), ("Logo_256.png", 256),
    ("Logo_256-1.png", 256), ("Logo_512.png", 512), ("Logo_512-1.png", 512),
    ("Logo_1024.png", 1024)
]
for (name, size) in files {
    try! render(size: size).write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    print("\(name)  \(size)x\(size)")
}
