// Renders the app icon into an .iconset: an ichthys whose two outlines are two Git branches.
// They leave one commit at the mouth and merge again where the tail crosses.
// usage: swift make-icon.swift <out.iconset> [preview.png]
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    // Squircle plate (macOS grid: 824/1024 body, centred).
    let inset = s * 0.0977
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let plate = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [hex(0x2B1726), hex(0x150F15)])!.draw(in: plate, angle: -90)
    // A faint moonlit glow behind the fish.
    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    let glow = NSGradient(colors: [hex(0xB0466A, 0.22), hex(0xB0466A, 0)])!
    glow.draw(fromCenter: NSPoint(x: rect.midX + rect.width * 0.06, y: rect.midY + rect.width * 0.04), radius: 0,
              toCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width * 0.55, options: [])
    NSGraphicsContext.restoreGraphicsState()
    hex(0xEDE6DD, 0.07).setStroke(); plate.lineWidth = max(1, s * 0.004); plate.stroke()

    let w = rect.width, ox = rect.minX, oy = rect.minY
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + w * x, y: oy + w * (1 - y)) }   // y down, 0…1

    let rose = hex(0xD3708F), olive = hex(0xAAB57A)
    let lw = w * 0.046

    // Each branch is one cubic: mouth -> along the body -> through the crossing -> tail tip.
    let m: (CGFloat, CGFloat) = (0.79, 0.50)
    let up: [(CGFloat, CGFloat)] = [m, (0.60, 0.15), (0.33, 0.22), (0.15, 0.71)]
    let dn: [(CGFloat, CGFloat)] = [m, (0.60, 0.85), (0.33, 0.78), (0.15, 0.29)]
    func at(_ c: [(CGFloat, CGFloat)], _ t: CGFloat) -> NSPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, cc = 3 * u * t * t, d = t * t * t
        return p(a * c[0].0 + b * c[1].0 + cc * c[2].0 + d * c[3].0, a * c[0].1 + b * c[1].1 + cc * c[2].1 + d * c[3].1)
    }
    func path(_ c: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let b = NSBezierPath(); b.move(to: p(c[0].0, c[0].1))
        b.curve(to: p(c[3].0, c[3].1), controlPoint1: p(c[1].0, c[1].1), controlPoint2: p(c[2].0, c[2].1))
        b.lineWidth = lw; b.lineCapStyle = .round; return b
    }
    olive.setStroke(); path(dn).stroke()
    rose.setStroke(); path(up).stroke()

    func node(_ c: NSPoint, _ r: CGFloat, _ col: NSColor, hole: CGFloat = 0.44) {
        col.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        let r2 = r * hole
        hex(0x1E141C).setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - r2, y: c.y - r2, width: r2 * 2, height: r2 * 2)).fill()
    }
    // HEAD at the mouth: the commit both branches start from, with a soft halo like in the graph.
    let mp = p(m.0, m.1), hr = w * 0.092
    rose.withAlphaComponent(0.22).setFill()
    NSBezierPath(ovalIn: NSRect(x: mp.x - hr, y: mp.y - hr, width: hr * 2, height: hr * 2)).fill()
    node(mp, w * 0.058, rose)
    node(at(up, 0.36), w * 0.05, rose)
    node(at(dn, 0.36), w * 0.05, olive)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
if CommandLine.arguments.count > 2 { try! render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
