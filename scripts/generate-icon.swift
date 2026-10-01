#!/usr/bin/env swift
// Draws the FanBar app icon and writes Resources/AppIcon.icns plus a 1024px PNG.
//
// Same family as Calendo's icon: a dark tile, a light inner card, and the
// subject in the shared slate blue.
import AppKit
import Foundation

let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let root = script.deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")

let canvas = 1024.0
let tile = 824.0
let origin = (canvas - tile) / 2
let radius = tile * 0.223
let blue = NSColor(srgbRed: 0.25, green: 0.43, blue: 0.53, alpha: 1)
let page = NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
let ink = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.16, alpha: 1)
let pale = NSColor(srgbRed: 0.82, green: 0.86, blue: 0.89, alpha: 1)

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// One blade pointing up from the hub, swept to the right like a real fan blade.
func blade(length: CGFloat, width: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: -width * 0.18, y: 0))
    path.curve(
        to: NSPoint(x: width * 0.55, y: length),
        controlPoint1: NSPoint(x: -width * 0.95, y: length * 0.45),
        controlPoint2: NSPoint(x: -width * 0.35, y: length * 1.02)
    )
    path.curve(
        to: NSPoint(x: width * 0.18, y: 0),
        controlPoint1: NSPoint(x: width * 1.05, y: length * 0.95),
        controlPoint2: NSPoint(x: width * 0.55, y: length * 0.3)
    )
    path.close()
    return path
}

/// Draws in a 1024pt, y-up space.
func drawIcon() {
    ink.setFill()
    roundedRect(NSRect(x: origin, y: origin, width: tile, height: tile), radius: radius).fill()

    let inset = tile * 0.14
    let card = NSRect(x: origin + inset, y: origin + inset, width: tile - inset * 2, height: tile - inset * 2)
    page.setFill()
    roundedRect(card, radius: radius * 0.42).fill()

    let center = NSPoint(x: card.midX, y: card.midY)
    let housing = card.width * 0.4

    // Pale housing ring behind the blades.
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - housing, y: center.y - housing, width: housing * 2, height: housing * 2))
    ring.lineWidth = card.width * 0.035
    pale.setStroke()
    ring.stroke()

    let length = housing * 0.84
    let width = housing * 0.5
    blue.setFill()
    for index in 0..<4 {
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: CGFloat(index) * 90 + 12)
        let path = blade(length: length, width: width)
        path.transform(using: transform as AffineTransform)
        path.fill()
    }

    let hub = housing * 0.2
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)).fill()
    let cap = hub * 0.42
    page.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - cap, y: center.y - cap, width: cap * 2, height: cap * 2)).fill()
}

func png(pixels: Int) -> Data {
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create bitmap") }
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    guard let image = ctx.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("Could not encode PNG") }
    return data
}

let output = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : resources
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try png(pixels: 1024).write(to: output.appendingPathComponent("AppIcon.png"))

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("Wrote AppIcon.icns and AppIcon.png in \(output.path)")
