// Renders the AirClick icon: a dark rounded square, a white mouse capsule,
// and wavy "air" streams rising from it. Outputs a 1024px PNG.
import CoreGraphics
import ImageIO
import Foundation

let S: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Background squircle with a soft diagonal gradient.
let radius: CGFloat = 228
let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S), cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(bg)
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [color(0x27, 0x2b, 0x35), color(0x0e, 0x10, 0x15)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [.drawsAfterEndLocation])
// Subtle radial glow behind the mouse (cool blue, low alpha).
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [color(0x59, 0x76, 0xff, 0.20), color(0x59, 0x76, 0xff, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 380), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 380), endRadius: 460, options: [.drawsAfterEndLocation])
ctx.restoreGState()

// Air/wind streams: wavy strokes rising from behind the mouse.
func wave(from p: CGPoint, amp: CGFloat, lift: CGFloat, width: CGFloat, alpha: CGFloat) {
  let path = CGMutablePath()
  path.move(to: p)
  path.addCurve(to: CGPoint(x: p.x + 150, y: p.y + lift + amp),
                control1: CGPoint(x: p.x + 35, y: p.y + lift - amp * 0.4),
                control2: CGPoint(x: p.x + 95, y: p.y + lift + amp * 0.9))
  path.addCurve(to: CGPoint(x: p.x + 320, y: p.y + lift * 2.2 + amp * 0.4),
                control1: CGPoint(x: p.x + 205, y: p.y + lift * 1.5 + amp * 1.25),
                control2: CGPoint(x: p.x + 260, y: p.y + lift * 1.6 + amp * 0.1))
  path.addCurve(to: CGPoint(x: p.x + 520, y: p.y + lift * 3.1),
                control1: CGPoint(x: p.x + 390, y: p.y + lift * 2.5 - amp * 0.3),
                control2: CGPoint(x: p.x + 460, y: p.y + lift * 2.8 + amp * 0.5))
  ctx.addPath(path)
  ctx.setStrokeColor(color(0xec, 0xf1, 0xff, alpha))
  ctx.setLineWidth(width)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  ctx.strokePath()
}
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: color(0, 0, 0, 0.35))
wave(from: CGPoint(x: 470, y: 560), amp: 58, lift: 95, width: 40, alpha: 0.96)
wave(from: CGPoint(x: 470, y: 470), amp: 52, lift: 78, width: 32, alpha: 0.66)
wave(from: CGPoint(x: 470, y: 384), amp: 46, lift: 64, width: 26, alpha: 0.40)
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// The mouse: a white capsule with a seam and a scroll slot.
let mx: CGFloat = 292, my: CGFloat = 118, mw: CGFloat = 440, mh: CGFloat = 292
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, 0, 0, 0.45))
ctx.setFillColor(color(0xf4, 0xf6, 0xfa))
let mouse = CGPath(roundedRect: CGRect(x: mx, y: my, width: mw, height: mh), cornerWidth: mh / 2, cornerHeight: mh / 2, transform: nil)
ctx.addPath(mouse)
ctx.fillPath()
ctx.restoreGState()

// Seam between the two button halves (top half only), like a classic mouse.
ctx.setStrokeColor(color(0x2a, 0x2e, 0x38, 0.9))
ctx.setLineWidth(18)
ctx.setLineCap(.round)
ctx.addLines(between: [CGPoint(x: 512, y: my + mh - 24), CGPoint(x: 512, y: my + mh / 2 + 8)])
ctx.strokePath()
// Scroll wheel slot right above the seam.
ctx.setFillColor(color(0x2a, 0x2e, 0x38, 0.9))
let slot = CGPath(roundedRect: CGRect(x: 512 - 22, y: my + mh / 2 + 58, width: 44, height: 84), cornerWidth: 22, cornerHeight: 22, transform: nil)
ctx.addPath(slot)
ctx.fillPath()

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")