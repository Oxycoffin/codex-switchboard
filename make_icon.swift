import AppKit
import Foundation

let destination = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let outer = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 220, yRadius: 220)
NSGraphicsContext.current?.saveGraphicsState()
outer.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.55, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.53, green: 0.28, blue: 0.96, alpha: 1)
])!
gradient.draw(in: outer, angle: -45)
NSGraphicsContext.current?.restoreGraphicsState()

NSColor.white.withAlphaComponent(0.14).setStroke()
outer.lineWidth = 8
outer.stroke()

let configuration = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) {
    let symbolRect = NSRect(x: 252, y: 252, width: 520, height: 520)
    symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
}

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("No se pudo generar el icono")
}
try png.write(to: URL(fileURLWithPath: destination), options: .atomic)
