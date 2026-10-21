// Renders the AirClick icon — minimal: near-black squircle, a white outlined
// mouse capsule with a scroll slot, and a single air-wave stream rising off
// it. Outputs a 1024px PNG: `swift assets/make-icon.swift assets/icon.png`
import CoreGraphics
import ImageIO
import Foundation

let S: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Flat near-black squircle, no gradient, no glow.
let black = CGColor(srgbRed: 0x0a / 255, green: 0x0b / 255, blue: 0x0d / 255, alpha: 1)
ctx.setFillColor(black)
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                   cornerWidth: 228, cornerHeight: 228, transform: nil))
ctx.fillPath()

let white = CGColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
ctx.setStrokeColor(white)
ctx.setLineWidth(26)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Mouse capsule, drawn as an outline, lower-left of center.
let mouse = CGPath(roundedRect: CGRect(x: 268, y: 198, width: 322, height: 226),
                   cornerWidth: 113, cornerHeight: 113, transform: nil)
ctx.addPath(mouse)
ctx.strokePath()

// Scroll slot: one short line inside the top-center of the capsule.
ctx.addLines(between: [CGPoint(x: 429, y: 396), CGPoint(x: 429, y: 336)])
ctx.strokePath()

// The air: a single wave rising off the top-right shoulder of the mouse.
// The two curves share a tangent at the joint, so the stream bends smoothly.
let wave = CGMutablePath()
wave.move(to: CGPoint(x: 498, y: 474))
wave.addCurve(to: CGPoint(x: 618, y: 652),
              control1: CGPoint(x: 568, y: 470), control2: CGPoint(x: 606, y: 560))
wave.addCurve(to: CGPoint(x: 806, y: 812),
              control1: CGPoint(x: 642, y: 747), control2: CGPoint(x: 716, y: 800))
ctx.addPath(wave)
ctx.strokePath()

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")