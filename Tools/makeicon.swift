// Renders the OpenCapture app icon to a 1024x1024 PNG. Run: makeicon out.png
import AppKit

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-square backdrop with a deep teal→indigo gradient.
let inset: CGFloat = 70
let rect = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
path.addClip()
let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.62, alpha: 1),
                                   NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.45, alpha: 1)])!
gradient.draw(in: rect, angle: -60)

// Subtle "scanline" stripes to hint at video.
ctx.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
var y = rect.minY
while y < rect.maxY { ctx.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: 10)); y += 40 }

// Video glyph: a 16:9 frame with a record dot and a play triangle.
let frame = CGRect(x: 232, y: 332, width: 560, height: 360)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(44)
ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 48, cornerHeight: 48, transform: nil))
ctx.strokePath()

ctx.setFillColor(NSColor.white.cgColor)
let tri = CGMutablePath()
tri.move(to: CGPoint(x: 430, y: 420)); tri.addLine(to: CGPoint(x: 430, y: 604)); tri.addLine(to: CGPoint(x: 630, y: 512)); tri.closeSubpath()
ctx.addPath(tri); ctx.fillPath()

ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.25, blue: 0.3, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: 700, y: 720, width: 100, height: 100))

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
