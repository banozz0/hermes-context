// Renders .github/social-preview.png, the 1280x640 GitHub link preview, from .github/screenshot.png.
// Run from the repo root: swift .github/social-preview.swift
// GitHub has no API for the preview: upload the PNG in Settings, General, Social preview.
import AppKit

let width = 1280, height = 640
let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
guard let shot = NSImage(contentsOf: dir.appendingPathComponent("screenshot.png")),
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                 samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 32)
else { fatalError("social-preview: cannot read screenshot.png") }

NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
NSGradient(starting: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1),
           ending: NSColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color])
        .draw(at: NSPoint(x: 88, y: y))
}
text("Hermes Context", size: 76, weight: .bold, color: .white, y: 350)
let dim = NSColor(white: 0.78, alpha: 1)
text("Live Hermes Discord sessions", size: 36, weight: .regular, color: dim, y: 290)
text("in your menu bar.", size: 36, weight: .regular, color: dim, y: 244)
text("macOS app · open source · github.com/banozz0/hermes-context", size: 22, weight: .medium,
     color: NSColor(srgbRed: 0.98, green: 0.62, blue: 0.2, alpha: 1), y: 160)

let size = NSSize(width: shot.size.width * 1.2, height: shot.size.height * 1.2)
let frame = NSRect(origin: NSPoint(x: CGFloat(width) - size.width - 96, y: (CGFloat(height) - size.height) / 2), size: size)
let card = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
shadow.shadowBlurRadius = 36
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
card.fill()
card.addClip()
shot.draw(in: frame)
NSGraphicsContext.restoreGraphicsState()
NSColor(white: 1, alpha: 0.12).setStroke()
card.stroke()

try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("social-preview.png"))
