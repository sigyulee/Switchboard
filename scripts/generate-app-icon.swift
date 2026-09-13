// SPDX-License-Identifier: AGPL-3.0-only
// Original vector drawing. Raster output is generated locally and is not source-release content.
import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = points * factor
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            fatalError("Could not create icon drawing surface")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = CGFloat(pixels) / 64
        NSColor(srgbRed: 0.10, green: 0.43, blue: 0.91, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            xRadius: 14 * scale, yRadius: 14 * scale
        ).fill()
        NSColor.white.setFill()
        for (index, height) in [10.0, 26, 42, 26, 10].enumerated() {
            let rect = NSRect(
                x: (10 + Double(index) * 10) * scale,
                y: (32 - height / 2) * scale, width: 4 * scale, height: height * scale)
            NSBezierPath(roundedRect: rect, xRadius: 2 * scale, yRadius: 2 * scale).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode icon drawing")
        }
        let suffix = factor == 2 ? "@2x" : ""
        try png.write(to: folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
