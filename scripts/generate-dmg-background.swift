#!/usr/bin/env swift
// Background for the disk image's install window, same layout as Calendo's.
// Finder draws the app and Applications icons itself at (170, 175) and
// (550, 175), 128pt wide; this image only fills the gap with "drag and drop"
// and a curved arrow pointing at Applications. scripts/make-dmg.sh uses the
// same positions.
//
// Writes Resources/dmg/background.tiff with 1x and 2x images, so the type
// stays sharp on retina.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("Resources/dmg")

let width = 720.0
let height = 400.0
let iconCenterY = 175.0
let appRight = 170.0 + 64.0
let folderLeft = 550.0 - 64.0
let ink = NSColor(srgbRed: 0.25, green: 0.43, blue: 0.53, alpha: 1)

func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

func render(scale: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Could not create bitmap") }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let ctx = context.cgContext

    NSColor.white.setFill()
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Bitmap coordinates are y-up; Finder positions are y-down.
    let y = height - iconCenterY
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    NSAttributedString(
        string: "drag and drop",
        attributes: [.font: roundedFont(size: 28, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style]
    ).draw(in: NSRect(x: 0, y: y + 16, width: width, height: 34))

    let start = CGPoint(x: appRight + 18, y: y - 6)
    let end = CGPoint(x: folderLeft - 10, y: y + 2)
    let control1 = CGPoint(x: start.x + 70, y: start.y - 58)
    let control2 = CGPoint(x: end.x - 95, y: end.y - 52)
    let head = 14.0
    let length = hypot(end.x - control2.x, end.y - control2.y)
    let ux = (end.x - control2.x) / length
    let uy = (end.y - control2.y) / length
    let base = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
    let shaftEnd = CGPoint(x: end.x - ux * head * 0.45, y: end.y - uy * head * 0.45)

    ctx.setStrokeColor(ink.cgColor)
    ctx.setFillColor(ink.cgColor)
    ctx.setLineWidth(4.25)
    ctx.setLineCap(.round)
    ctx.move(to: start)
    ctx.addCurve(to: shaftEnd, control1: control1, control2: control2)
    ctx.strokePath()

    ctx.move(to: end)
    ctx.addLine(to: CGPoint(x: base.x - uy * head * 0.58, y: base.y + ux * head * 0.58))
    ctx.addLine(to: CGPoint(x: base.x + uy * head * 0.58, y: base.y - ux * head * 0.58))
    ctx.closePath()
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("Could not encode PNG") }
    return png
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let temp = FileManager.default.temporaryDirectory
let oneX = temp.appendingPathComponent("background.png")
let twoX = temp.appendingPathComponent("background@2x.png")
try render(scale: 1).write(to: oneX)
try render(scale: 2).write(to: twoX)

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", oneX.path, twoX.path, "-out", output.appendingPathComponent("background.tiff").path]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { fatalError("tiffutil failed") }
try? FileManager.default.removeItem(at: oneX)
try? FileManager.default.removeItem(at: twoX)
print("Wrote \(output.appendingPathComponent("background.tiff").path)")
