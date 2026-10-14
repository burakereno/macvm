// Render the actual shared artwork at Dock sizes without starting a VM.
import AppKit
import MacVMCore
import MacVMUI

@main struct GuestIconPreview {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for brand in [GuestBrand.macOS, .ubuntu, .windows, .linux] {
            for size in [32, 64, 256] {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                GuestBrandArtwork.dockIcon(for: brand).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(brand.rawValue)-\(size).png"))
            }
        }
    }
}
