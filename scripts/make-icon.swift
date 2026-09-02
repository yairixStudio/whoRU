#!/usr/bin/env swift
// Renders the app icon: a rounded square in system blue with the
// person.fill.questionmark symbol, then packs it into an .icns.
// usage: swift scripts/make-icon.swift build/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.icns"
let iconset = NSString(string: output).deletingPathExtension + ".iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let inset = s * 0.05
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.98, alpha: 1), ending: NSColor(calibratedRed: 0.05, green: 0.36, blue: 0.85, alpha: 1))!
    gradient.draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "person.fill.questionmark", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { drawRect in
            symbol.draw(in: drawRect)
            NSColor.white.set()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        let symbolSize = tinted.size
        let origin = NSPoint(x: (s - symbolSize.width) / 2, y: (s - symbolSize.height) / 2 + s * 0.02)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    return image
}

for (size, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let image = render(size)
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", output]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
print(task.terminationStatus == 0 ? "wrote \(output)" : "iconutil failed")
