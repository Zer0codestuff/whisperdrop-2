import AppKit
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 210, yRadius: 210).fill()
NSColor(calibratedRed: 43/255, green: 214/255, blue: 107/255, alpha: 1).setFill()
let heights: [CGFloat] = [130, 240, 380, 500, 300, 175, 95]
for (i, h) in heights.enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 250 + CGFloat(i) * 78, y: (1024 - h) / 2, width: 42, height: h), xRadius: 21, yRadius: 21).fill()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
