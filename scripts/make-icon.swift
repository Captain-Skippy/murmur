#!/usr/bin/env swift
// Draws Murmur's app icon with CoreGraphics at every iconset size and packs it with iconutil.
// Usage: swift scripts/make-icon.swift [out.icns]   (default Resources/AppIcon.icns)
// Also writes build/icon/AppIcon-1024.png for review.
import AppKit
import SwiftUI

let space = CGColorSpace(name: CGColorSpace.displayP3)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

// Palette: aqua at the top left, through teal, to deep blue. The app's accent is the teal.
let top = rgb(0x4BE3C4), mid = rgb(0x0FA0A6), bottom = rgb(0x173F94)
let shade = rgb(0x071A45)
// The caret: the one warm element, where voice becomes text.
let caretTop = rgb(0xFFC65C), caretBottom = rgb(0xFF8A3D)

/// Draws the icon into a square context of `px` pixels. Geometry is on Apple's 1024 grid.
func draw(_ c: CGContext, px: Int) {
    let k = CGFloat(px) / 1024
    let small = px <= 32
    c.scaleBy(x: k, y: k)
    // Flip so y grows downward like the design grid.
    c.translateBy(x: 0, y: 1024); c.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: body).cgPath
    let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

    c.saveGState()
    c.addPath(squircle); c.clip()
    // Base: a diagonal ramp.
    let base = CGGradient(colorsSpace: space, colors: [top, mid, bottom] as CFArray, locations: [0, 0.5, 1])!
    c.drawLinearGradient(base, start: CGPoint(x: 230, y: 100), end: CGPoint(x: 794, y: 924), options: extend)
    // Light from the top left.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: 320, y: 150), startRadius: 0,
                         endCenter: CGPoint(x: 320, y: 150), endRadius: 600, options: [])
    // Depth at the bottom.
    let dark = CGGradient(colorsSpace: space, colors: [shade.copy(alpha: 0)!, shade.copy(alpha: 0.35)!] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(dark, start: CGPoint(x: 512, y: 600), end: CGPoint(x: 512, y: 924), options: [])

    // Glyph: four bars of voice, then a text caret.
    let heights: [CGFloat] = [0.40, 0.76, 1.0, 0.56]
    let w: CGFloat = small ? 88 : 76, gap: CGFloat = small ? 36 : 40, maxH: CGFloat = 452
    let caretW: CGFloat = small ? 44 : 34, caretGap: CGFloat = small ? 52 : 58, caretH = maxH * 0.86
    let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap + caretGap + caretW
    var x = 512 - total / 2
    let bars = CGMutablePath()
    for h in heights {
        let hh = max(w, maxH * h)
        bars.addPath(CGPath(roundedRect: CGRect(x: x, y: 512 - hh / 2, width: w, height: hh), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
        x += w + gap
    }
    x += caretGap - gap
    let caret = CGPath(roundedRect: CGRect(x: x, y: 512 - caretH / 2, width: caretW, height: caretH),
                       cornerWidth: caretW / 2, cornerHeight: caretW / 2, transform: nil)

    // Soft shadow under the glyph.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -16 * k), blur: 40 * k, color: shade.copy(alpha: 0.5))
    c.addPath(bars); c.addPath(caret); c.setFillColor(rgb(0xFFFFFF)); c.fillPath()
    c.restoreGState()
    // Bars: white, cooling slightly toward the bottom.
    c.saveGState()
    c.addPath(bars); c.clip()
    let ink = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xD8F4F2)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(ink, start: CGPoint(x: 512, y: 286), end: CGPoint(x: 512, y: 738), options: extend)
    c.restoreGState()
    c.saveGState()
    c.addPath(caret); c.clip()
    let warm = CGGradient(colorsSpace: space, colors: [caretTop, caretBottom] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(warm, start: CGPoint(x: 512, y: 512 - caretH / 2), end: CGPoint(x: 512, y: 512 + caretH / 2), options: extend)
    c.restoreGState()

    // Rim light: a thin bright edge along the top, fading down the sides.
    if !small {
        c.addPath(squircle)
        c.setLineWidth(6)
        c.replacePathWithStrokedPath()
        c.clip()
        let rim = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.5), rgb(0xFFFFFF, 0.0), rgb(0xFFFFFF, 0.08)] as CFArray, locations: [0, 0.45, 1])!
        c.drawLinearGradient(rim, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    }
    c.restoreGState()
}

func png(px: Int, to url: URL) {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    draw(c, px: px)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : root.appendingPathComponent("Resources/AppIcon.icns")
let work = root.appendingPathComponent("build/icon")
let set = work.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    png(px: pt, to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    png(px: pt * 2, to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
png(px: 1024, to: work.appendingPathComponent("AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(out.path)")
