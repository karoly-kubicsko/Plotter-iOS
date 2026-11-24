import SwiftUI

#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

// Small shims that let the shared SwiftUI code build for macOS (AppKit) and iOS (UIKit).

extension PlatformColor {
    /// A colour that resolves to `light` or `dark` with the current appearance.
    static func dynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        #if canImport(AppKit)
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
        #else
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        #endif
    }

    static func srgb(_ hex: UInt32) -> PlatformColor {
        PlatformColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                      green: CGFloat((hex >> 8) & 0xFF) / 255,
                      blue: CGFloat(hex & 0xFF) / 255,
                      alpha: 1)
    }

    /// The background of text fields and graphs.
    static var plotBackground: PlatformColor {
        #if canImport(AppKit)
        .textBackgroundColor
        #else
        .systemBackground
        #endif
    }

    /// The default colour of text.
    static var plotLabel: PlatformColor {
        #if canImport(AppKit)
        .labelColor
        #else
        .label
        #endif
    }
}

extension Color {
    init(platform color: PlatformColor) {
        #if canImport(AppKit)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}

@MainActor
func copyToPasteboard(_ string: String) {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #else
    UIPasteboard.general.string = string
    #endif
}
