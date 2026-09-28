// Renders .github/social-preview.png (1280x640): run `swift .github/social-preview.swift`, then upload the PNG by hand in GitHub Settings, General, Social preview.
// The popover is redrawn in vector from the made-up sessions in screenshot.png, so it stays sharp at 1.45x.
import AppKit

let W: CGFloat = 1280, H: CGFloat = 640
let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

func channels(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
    (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
}
func rgb(_ hex: UInt32) -> NSColor { let c = channels(hex); return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }
let orange = rgb(0xFF9F0A), green = rgb(0x30D158), grey = rgb(0x8E8E93), teal = rgb(0x1691A0)
// Shared by the hero aurora and the screen's wallpaper.
let tealLight: UInt32 = 0x1797A6, tealDeep: UInt32 = 0x0F5E68, tealGlow: UInt32 = 0x5FE0D2
let white = NSColor.white
func white(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, mono: Bool = false) -> NSFont {
    mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
}
/// Draws one line on a baseline; returns its width.
@discardableResult
func text(_ s: String, _ f: NSFont, _ c: NSColor, x: CGFloat, baseline: CGFloat, kern: CGFloat = 0, right: Bool = false) -> CGFloat {
    let str = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern])
    let w = str.size().width
    str.draw(at: NSPoint(x: right ? x - w : x, y: baseline - f.ascender))
    return w
}
/// An SF Symbol in one colour, centred on `center`.
func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, center: NSPoint) {
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))!
    let tinted = NSImage(size: base.size, flipped: false) { r in
        base.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true
    }
    tinted.draw(in: NSRect(origin: NSPoint(x: center.x - base.size.width / 2, y: center.y - base.size.height / 2), size: base.size),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}
func rrect(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }
func glow(_ c: NSColor, _ center: NSPoint, _ radius: CGFloat, _ a: CGFloat) {
    NSGradient(colors: [c.withAlphaComponent(a), c.withAlphaComponent(a * 0.45), c.withAlphaComponent(0)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}
func shadowed(_ color: NSColor, blur: CGFloat, dy: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow(); s.shadowColor = color; s.shadowBlurRadius = blur; s.shadowOffset = NSSize(width: 0, height: -dy)
    s.set(); body()
    NSGraphicsContext.restoreGraphicsState()
}
func scaled(_ origin: NSPoint, _ s: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: origin.x, yBy: origin.y); t.scale(by: s); t.concat()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

// The made-up sessions from screenshot.png, in its order. meta is profile, state, channel, model.
struct Row {
    let name: String; let meta: [String]; let age: String; let pct: Int
    var dot: NSColor { ["Needs attention": orange, "Working": green][meta[1]] ?? grey }
}
let rows = [
    Row(name: "Checkout bug repro", meta: ["Default", "Needs attention", "#dev", "claude-opus-5-5"], age: "3m", pct: 27),
    Row(name: "Landing page rewrite", meta: ["Default", "Working", "#web", "claude-opus-5-5"], age: "now", pct: 42),
    Row(name: "Staging deploy", meta: ["Ops", "Working", "#deploys", "claude-haiku-4-5"], age: "now", pct: 12),
    Row(name: "Vector database comparison", meta: ["Research", "Working", "#research", "gpt-5"], age: "now", pct: 34),
    Row(name: "Competitor pricing notes", meta: ["Research", "Idle", "#research", "claude-sonnet-5"], age: "41m", pct: 18),
    Row(name: "Weekly metrics digest", meta: ["Default", "Idle", "#general", "claude-sonnet-5"], age: "3h", pct: 9),
    Row(name: "Nightly backup check", meta: ["Ops", "Idle", "#alerts", "claude-haiku-4-5"], age: "6h", pct: 4),
]
let threshold = 30

/// The popover in the app's own 1x point metrics, scaled by `s`, running off the bottom edge.
func popover(at origin: NSPoint, scale s: CGFloat) {
    let w: CGFloat = 352, frame = NSRect(x: 0, y: 0, width: w, height: H / s), panel = rgb(0x1E2426)
    scaled(origin, s) {
        let shape = rrect(frame, 12)
        shadowed(NSColor(white: 0, alpha: 0.7), blur: 40 / s, dy: 16 / s) { panel.setFill(); shape.fill() }
        shape.addClip()
        NSGradient(starting: rgb(0x243034), ending: panel)!.draw(in: NSRect(x: 0, y: 0, width: w, height: 120), angle: 90)
        symbol("exclamationmark.triangle.fill", size: 9.5, weight: .semibold, color: orange, center: NSPoint(x: 16, y: 16.5))
        text("Context at or above \(threshold)%", font(10, .semibold), orange, x: 26, baseline: 20)
        for (i, r) in rows.filter({ $0.pct >= threshold }).enumerated() {
            let y = 36 + CGFloat(i) * 15
            text("\(r.name) · \(r.meta[0])", font(10), white(0.92), x: 10, baseline: y)
            text("\(r.pct)%", font(10, mono: true), white(0.92), x: w - 10, baseline: y, right: true)
        }
        white(0.09).setFill(); NSRect(x: 0, y: 58, width: w, height: 0.75).fill()
        for (i, r) in rows.enumerated() {
            let top = 60 + CGFloat(i) * 43
            r.dot.setFill(); NSBezierPath(ovalIn: NSRect(x: 10, y: top + 11.5, width: 8, height: 8)).fill()
            text(r.name, font(13, .medium), white(0.96), x: 26, baseline: top + 20)
            var x: CGFloat = 26
            for (j, part) in r.meta.enumerated() {
                if j > 0 { x += text(" · ", font(10), white(0.6), x: x, baseline: top + 35) }
                x += text(part, font(10, j == 0 ? .medium : .regular), white(0.62), x: x, baseline: top + 35)
            }
            text("\(r.pct)%", font(13, .semibold, mono: true), r.pct >= threshold ? orange : white(0.96), x: w - 10, baseline: top + 20, right: true)
            text(r.age, font(10), white(0.62), x: w - 10, baseline: top + 35, right: true)
        }
    }
    scaled(origin, s) {
        white(0.14).setStroke(); let edge = rrect(frame.insetBy(dx: 0.25, dy: 0.25), 12); edge.lineWidth = 0.5; edge.stroke()
    }
}

// MARK: the hero shader: a seeded aurora behind the title, fading into ink before the screen.

/// Deterministic per-lattice-point noise in 0...1.
func hash(_ x: Int, _ y: Int, _ seed: UInt32) -> Double {
    var h = (UInt32(truncatingIfNeeded: x) &* 0x27D4_EB2D) ^ (UInt32(truncatingIfNeeded: y) &* 0x1656_67B1) ^ seed
    h = (h ^ (h >> 15)) &* 0x2C1B_3C6D
    h = (h ^ (h >> 12)) &* 0x297A_2D39
    return Double(h ^ (h >> 15)) / Double(UInt32.max)
}
func noise(_ x: Double, _ y: Double) -> Double {
    let x0 = x.rounded(.down), y0 = y.rounded(.down), i = Int(x0), j = Int(y0), fx = x - x0, fy = y - y0
    let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
    let a = hash(i, j, 7), b = hash(i + 1, j, 7), c = hash(i, j + 1, 7), d = hash(i + 1, j + 1, 7)
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
}
func fbm(_ x: Double, _ y: Double) -> Double {
    var sum = 0.0, amp = 0.5, f = 1.0
    for _ in 0..<3 { sum += amp * noise(x * f, y * f); f *= 2.03; amp *= 0.5 }
    return sum / 0.875
}
func byte(_ v: Double) -> UInt8 { UInt8(min(max(v * 255, 0), 255).rounded()) }
func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
}

/// Writes the background straight into the bitmap: ink, a domain-warped aurora of soft colour blobs
/// streaked into ribbons, and monochrome film grain. Blob centres and radii are in units of the canvas height.
/// The aurora fades out over the 280 px before `screenLeft`.
func aurora(_ rep: NSBitmapImageRep, screenLeft: Double) {
    let blobs: [(x: Double, y: Double, radius: Double, strength: Double, color: (r: Double, g: Double, b: Double))] = [
        (0.00, 0.10, 0.55, 0.50, channels(tealLight)),
        (0.45, 0.55, 0.45, 0.50, channels(tealDeep)),
        (0.28, -0.05, 0.25, 0.25, channels(tealGlow)),
        (0.00, 1.10, 0.38, 0.48, channels(0xFF7A1A)),
    ]
    let ink = channels(0x0B0C0E), ribbonColor = channels(tealGlow)
    let fades = (0..<Int(W)).map { 1 - smoothstep(screenLeft - 280, screenLeft - 20, Double($0)) }
    let data = rep.bitmapData!, rowBytes = rep.bytesPerRow, step = rep.bitsPerPixel / 8
    for py in 0..<Int(H) {
        let y = Double(py) / Double(H)
        // Calmer directly behind the title and tagline (x 72-590, y 176-515), so the copy keeps its contrast.
        let cy = (y - 0.54) / 0.30
        for px in 0..<Int(W) {
            let fade = fades[px]
            var (r, g, b) = ink
            if fade > 0 {
                let x = Double(px) / Double(H), cx = (x - 0.52) / 0.46
                let light = fade * (1 - 0.6 * exp(-(cx * cx + cy * cy)))
                let sx = x * 1.4, sy = y * 1.4
                let wx = x + 0.5 * (fbm(sx + 1.7, sy + 9.2) - 0.5)
                let wy = y + 0.5 * (fbm(sx + 8.3, sy + 2.8) - 0.5)
                // Aurora ribbons: thin bright bands running diagonally through the warped field.
                let ribbon = pow(0.5 + 0.5 * sin((wx + wy * 2.2) * 9 + fbm(wx * 2, wy * 2) * 6), 8)
                var energy = 0.0
                for blob in blobs {
                    let dx = wx - blob.x, dy = wy - blob.y
                    let k = blob.strength * exp(-(dx * dx + dy * dy) / (blob.radius * blob.radius)) * light
                    energy += k
                    r += blob.color.r * k; g += blob.color.g * k; b += blob.color.b * k
                }
                let m = min(energy, 0.6)
                r += ribbonColor.r * ribbon * m * 0.45; g += ribbonColor.g * ribbon * m * 0.45; b += ribbonColor.b * ribbon * m * 0.45
            }
            let grain = (hash(px, py, 0xA5A5_1234) - 0.5) * (2 + 5 * fade) / 255
            let o = py * rowBytes + px * step
            data[o] = byte(r + grain); data[o + 1] = byte(g + grain); data[o + 2] = byte(b + grain)
        }
    }
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                                 samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 32),
      let cg = NSGraphicsContext(bitmapImageRep: rep)?.cgContext
else { fatalError("social-preview: cannot make a bitmap") }
cg.translateBy(x: 0, y: H); cg.scaleBy(x: 1, y: -1)  // top-left origin, like the app's own layout
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

// The top-left corner of a Mac screen, inside the 40 px safe border, running off the right and bottom edges.
let screen = NSRect(x: 640, y: 40, width: 760, height: 700), screenShape = rrect(screen, 26)
aurora(rep, screenLeft: screen.minX)
glow(teal, screen.origin, 700, 0.16)
shadowed(NSColor(srgbRed: 0.05, green: 0.55, blue: 0.6, alpha: 0.35), blur: 70, dy: 0) { rgb(0x0B3A40).setFill(); screenShape.fill() }
NSGraphicsContext.saveGraphicsState()
screenShape.addClip()
NSGradient(colors: [rgb(tealLight), rgb(tealDeep), rgb(0x0A2A30)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
    .draw(in: screen, angle: 90)
glow(rgb(tealGlow), NSPoint(x: 1180, y: 120), 420, 0.28)
let bar: CGFloat = 64, mid = screen.minY + bar / 2, itemX: CGFloat = 700
white(0.10).setFill(); NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: bar).fill()
NSColor(white: 0, alpha: 0.18).setFill(); NSRect(x: screen.minX, y: screen.minY + bar - 1, width: screen.width, height: 1).fill()
// The app's menu-bar item, open: the warning triangle and the working count.
white(0.26).setFill(); rrect(NSRect(x: itemX, y: mid - 23, width: 100, height: 46), 12).fill()
symbol("exclamationmark.triangle.fill", size: 27, weight: .semibold, color: white, center: NSPoint(x: itemX + 35, y: mid))
text("\(rows.filter { $0.meta[1] == "Working" }.count)", font(29, .semibold, mono: true), white, x: itemX + 60, baseline: mid + 10.5)
for (i, name) in ["wifi", "battery.100", "magnifyingglass", "switch.2"].enumerated() {
    symbol(name, size: 25, weight: .medium, color: white(0.9), center: NSPoint(x: 890 + CGFloat(i) * 84, y: mid))
}
popover(at: NSPoint(x: itemX, y: screen.minY + bar + 10), scale: 1.45)
NSGraphicsContext.restoreGraphicsState()
white(0.16).setStroke(); let rim = rrect(screen.insetBy(dx: 0.5, dy: 0.5), 26); rim.lineWidth = 1; rim.stroke()

// Name over tagline; kerning tightens with size.
let nameFont = font(124, .bold), tagFont = font(40, .medium)
let nameTop = 176 + nameFont.capHeight, tagTop = nameTop + nameFont.pointSize * 1.3 + tagFont.pointSize * 0.9
for (i, line) in ["Hermes", "Context"].enumerated() {
    text(line, nameFont, white, x: 72, baseline: nameTop + CGFloat(i) * nameFont.pointSize, kern: -nameFont.pointSize * 0.025)
}
for (i, line) in ["Live Hermes Discord sessions", "in your menu bar."].enumerated() {
    text(line, tagFont, white(0.8), x: 72, baseline: tagTop + CGFloat(i) * tagFont.pointSize * 1.25, kern: -tagFont.pointSize * 0.01)
}

try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("social-preview.png"))
