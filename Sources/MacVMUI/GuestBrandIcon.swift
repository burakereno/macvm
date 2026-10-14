import AppKit
import SwiftUI
import MacVMCore

public struct GuestBrandIcon: View {
    private let brand: GuestBrand
    public init(brand: GuestBrand) { self.brand = brand }
    public var body: some View {
        Image(nsImage: GuestBrandArtwork.glyph(for: brand))
            .renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(Color(nsColor: GuestBrandArtwork.color(for: brand)))
    }
}

/// Shared vector artwork for library rows and each runner's process-local Dock tile.
@MainActor public enum GuestBrandArtwork {
    private static var glyphs: [GuestBrand: NSImage] = [:]

    public static func color(for brand: GuestBrand) -> NSColor {
        switch brand {
        case .macOS: .systemGreen
        case .ubuntu: NSColor(srgbRed: 233 / 255, green: 80 / 255, blue: 14 / 255, alpha: 1)
        case .windows: NSColor(srgbRed: 0, green: 120 / 255, blue: 212 / 255, alpha: 1)
        case .linux: .systemOrange
        }
    }

    public static func glyph(for brand: GuestBrand) -> NSImage {
        if let image = glyphs[brand] { return image }
        let image: NSImage
        switch brand {
        case .macOS, .linux:
            image = NSImage(systemSymbolName: brand == .macOS ? "apple.logo" : "terminal", accessibilityDescription: brand.title)!
                .withSymbolConfiguration(.init(pointSize: 128, weight: .medium))!
        case .ubuntu:
            image = NSImage(data: Data(ubuntuSVG.utf8))!
        case .windows:
            image = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { _ in
                NSColor.black.setFill()
                for x in [CGFloat(0), 54] {
                    for y in [CGFloat(0), 54] {
                        NSBezierPath(rect: NSRect(x: x, y: y, width: 46, height: 46)).fill()
                    }
                }
                return true
            }
        }
        image.accessibilityDescription = brand.title
        glyphs[brand] = image
        return image
    }

    public static func dockIcon(for brand: GuestBrand) -> NSImage {
        let glyph = glyph(for: brand)
        // Tint on a separate transparent surface; sourceAtop must not whiten the tile.
        let whiteGlyph = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            NSColor.white.setFill(); rect.fill(using: .sourceAtop)
            return true
        }
        let accent = color(for: brand)
        let top = accent.blended(withFraction: 0.18, of: .white)!
        let bottom = accent.blended(withFraction: 0.12, of: .black)!
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let tile = NSBezierPath(roundedRect: NSRect(x: 27, y: 27, width: 458, height: 458), xRadius: 106, yRadius: 106)
            NSGradient(starting: top, ending: bottom)!.draw(in: tile, angle: -75)
            let scale = min(292 / glyph.size.width, 292 / glyph.size.height)
            let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
            whiteGlyph.draw(in: NSRect(x: (512 - size.width) / 2, y: (512 - size.height) / 2, width: size.width, height: size.height))
            return true
        }
    }

    // Canonical Circle of Friends artwork, kept as vector data (no network at runtime).
    // Source: https://assets.ubuntu.com/v1/ce518a18-CoF-2022_solid+O.svg
    private static let ubuntuSVG = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 767.40668 738.31421"><g fill="#e9500e"><circle cx="109.02696" cy="348.09412" r="109.02696"/><circle cx="563.08369" cy="109.02698" r="109.02698"/><path d="M492.48194,1336.66577a265.52505,265.52505,0,0,1-181.0712-138.09814,156.94784,156.94784,0,0,1-93.21911,11.45825,354.93524,354.93524,0,0,0,255.53723,214.16455,359.20777,359.20777,0,0,0,77.41949,7.967,156.00313,156.00313,0,0,1-31.92236-91.15466C510.24622,1340.00525,501.27735,1338.548,492.48194,1336.66577Z" transform="translate(-137.56155 -707.97998)"/><circle cx="538.52046" cy="629.28723" r="109.02698"/><path d="M827.798,1297.22095A356.70056,356.70056,0,0,0,845.67283,878.702a157.14441,157.14441,0,0,1-61.30975,71.8031,267.293,267.293,0,0,1-8.73688,265.4884A156.34677,156.34677,0,0,1,827.798,1297.22095Z" transform="translate(-137.56155 -707.97998)"/><path d="M238.17644,899.71906q4.1505-.22779,8.30533-.22553A157.34626,157.34626,0,0,1,329.16416,923.039,265.90653,265.90653,0,0,1,543.27238,808.52966a158.0877,158.0877,0,0,1,33.076-88.42022C439.24549,709.25177,306.02421,780.001,238.17644,899.71906Z" transform="translate(-137.56155 -707.97998)"/></g></svg>
    """#
}
