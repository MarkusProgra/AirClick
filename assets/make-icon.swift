// Renders the AirClick icon — ultra-minimal: a flat near-black squircle with
// a single horizontal curvy line (the air). One smooth wave, nothing else.
// `swift assets/make-icon.swift assets/icon.png`
import CoreGraphics
import ImageIO
import Foundation

let S: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Flat near-black squircle.
let black = CGColor(srgbRed: 0x0a / 255, green: 0x0b / 255, blue: 0x0d / 255, alpha: 1)
ctx.setFillColor(black)
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                   cornerWidth: 228, cornerHeight: 228, transform: nil))
ctx.fillPath()

// The air: one white wavering line flowing horizontally across the center.
// The two halves share a tangent at the joint, so the bend is seamless.
let white = CGColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
ctx.setStrokeColor(white)
ctx.setLineWidth(34)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let wave = CGMutablePath()
wave.move(to: CGPoint(x: 292, y: 545))
wave.addCurve(to: CGPoint(x: 512, y: 545),
              control1: CGPoint(x: 352, y: 399), control2: CGPoint(x: 412, y: 399))
wave.addCurve(to: CGPoint(x: 732, y: 545),
              control1: CGPoint(x: 612, y: 691), control2: CGPoint(x: 672, y: 691))
ctx.addPath(wave)
ctx.strokePath()

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")