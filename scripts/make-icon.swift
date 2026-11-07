// Renders Resources/AppIcon.icns and Resources/icon.png from Sources/VoxDesk/Logo.swift.
// build.sh compiles this together with Logo.swift; run it from the App folder.
import AppKit

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = ".build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(Logo.appIcon(size: CGFloat(px)), pixels: px).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    }
}
try png(Logo.appIcon(size: 512), pixels: 512).write(to: URL(fileURLWithPath: "Resources/icon.png"))
// The menu bar glyph at 4x, for the README and for checking the template by eye.
let menu = Logo.menuBarIcon()
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 88, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: 22, height: 16)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
menu.draw(in: NSRect(x: 0, y: 0, width: 22, height: 16))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/menubar@4x.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns, Resources/icon.png and Resources/menubar@4x.png" : "iconutil failed")
exit(p.terminationStatus)
