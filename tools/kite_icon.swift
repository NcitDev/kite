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

    // Squircle plate on the standard Big Sur 824pt inset.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.486, green: 0.424, blue: 1.000, alpha: 1),
            CGColor(red: 0.239, green: 0.157, blue: 0.722, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100),
                           options: [])
    ctx.restoreGState()

    let kite = kitePath()
    // Filling and stroking the same path with a round join rounds the four corners,
    // which keeps the silhouette from looking sharp and dated at large sizes.
    let corner: CGFloat = 46

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12),
                  blur: 34,
                  color: CGColor(red: 0.10, green: 0.05, blue: 0.35, alpha: 0.35))
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

    // Left half in a cooler tint reads as the fold in a piece of folded paper.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: 512, height: grid))
    ctx.addPath(kite)
    let fold = CGColor(red: 0.796, green: 0.776, blue: 0.976, alpha: 1)
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
