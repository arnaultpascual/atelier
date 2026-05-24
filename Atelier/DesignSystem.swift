// SPDX-License-Identifier: MIT
import SwiftUI

/// Atelier's visual language — adapted from Anthropic's Claude design charter:
/// warm cream backgrounds, terracotta orange accent, serif editorial titles.
///
/// Keep palette and typography centralized here so the rest of the app can read
/// from a single source of truth.
enum Palette {
    // Light mode — warm cream + ink
    static let creamLight = Color(red: 245/255, green: 244/255, blue: 238/255)   // #F5F4EE
    static let surfaceLight = Color(red: 250/255, green: 249/255, blue: 244/255) // #FAF9F4
    static let inkLight = Color(red: 31/255, green: 27/255, blue: 22/255)        // #1F1B16
    static let inkSecondaryLight = Color(red: 95/255, green: 89/255, blue: 81/255) // #5F5951
    static let dividerLight = Color(red: 224/255, green: 219/255, blue: 207/255) // #E0DBCF

    // Dark mode — warm near-black
    static let creamDark = Color(red: 30/255, green: 27/255, blue: 23/255)       // #1E1B17
    static let surfaceDark = Color(red: 38/255, green: 34/255, blue: 30/255)     // #26221E
    static let inkDark = Color(red: 240/255, green: 235/255, blue: 223/255)      // #F0EBDF
    static let inkSecondaryDark = Color(red: 173/255, green: 165/255, blue: 152/255) // #ADA598
    static let dividerDark = Color(red: 58/255, green: 52/255, blue: 46/255)     // #3A342E

    // Brand accent — Claude terracotta orange (works on both modes)
    static let claudeOrange = Color(red: 201/255, green: 100/255, blue: 66/255)  // #C96442
    static let claudeOrangeMuted = Color(red: 217/255, green: 119/255, blue: 87/255) // #D97757
    static let claudeOrangeSoft = Color(red: 240/255, green: 200/255, blue: 180/255).opacity(0.35)

    // Semantic
    static let success = Color(red: 99/255, green: 137/255, blue: 80/255)        // #638950 warm green
    static let warning = Color(red: 196/255, green: 138/255, blue: 50/255)       // #C48A32 warm amber
    static let error = Color(red: 178/255, green: 70/255, blue: 64/255)          // #B24640 warm red

    // Tonal greys for non-essential events
    static let stoneLight = Color(red: 142/255, green: 134/255, blue: 122/255)
    static let stoneDark = Color(red: 142/255, green: 134/255, blue: 122/255)
}

extension Color {
    /// Background fill of the app shell.
    static var atelierBackground: Color {
        Color(light: Palette.creamLight, dark: Palette.creamDark)
    }
    /// Slightly lighter than background — used for cards, controls.
    static var atelierSurface: Color {
        Color(light: Palette.surfaceLight, dark: Palette.surfaceDark)
    }
    /// Primary ink (body text).
    static var atelierInk: Color {
        Color(light: Palette.inkLight, dark: Palette.inkDark)
    }
    /// Secondary ink (captions, hints).
    static var atelierInkSecondary: Color {
        Color(light: Palette.inkSecondaryLight, dark: Palette.inkSecondaryDark)
    }
    /// Hairline divider.
    static var atelierDivider: Color {
        Color(light: Palette.dividerLight, dark: Palette.dividerDark)
    }
    /// Brand accent (Claude terracotta).
    static var atelierAccent: Color { Palette.claudeOrange }
    static var atelierAccentSoft: Color { Palette.claudeOrangeSoft }
}

extension Color {
    /// Creates a color with separate light/dark mode values.
    init(light: Color, dark: Color) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return NSColor(isDark ? dark : light)
        })
    }
}

/// Typography. Apple's "New York" serif (`.serif` design) for editorial titles,
/// system sans for body, mono for code.
enum AtelierFont {
    static let display = Font.system(.largeTitle, design: .serif).weight(.semibold)
    static let title = Font.system(.title2, design: .serif).weight(.semibold)
    static let subtitle = Font.system(.headline, design: .serif)
    static let body = Font.system(.body, design: .default)
    static let callout = Font.system(.callout, design: .default)
    static let caption = Font.system(.caption, design: .default)
    static let captionMono = Font.system(.caption, design: .monospaced)
    static let micro = Font.system(.caption2, design: .default)
    static let eyebrow = Font.system(.caption2, design: .monospaced).weight(.medium)
}

/// Drop-in shape vocabulary.
enum AtelierCorner {
    static let card: CGFloat = 10
    static let chip: CGFloat = 999
    static let control: CGFloat = 8
}

/// Shared layout constants for the multi-pane shell, so the bottom dividers
/// of the sidebar / chat rail / chat conversation headers land at the same
/// y position no matter which pane you're looking at.
enum AtelierLayout {
    /// Vertical reserve at the top of every pane so content sits below the
    /// macOS traffic-light area (the window is `.hiddenTitleBar`, so we own
    /// the chrome). 16pt is the visual offset the OS bakes in.
    static let paneHeaderTopReserve: CGFloat = 16

    /// Height of the title / brand / room-header content area. Same across
    /// panes so the divider underneath them aligns horizontally.
    static let paneHeaderContentHeight: CGFloat = 56
}

/// Atelier mark used in the top-left of the sidebar (and elsewhere): a mini
/// version of the app icon — the glowing copper "orbit" (central node + 8 nodes
/// on a ring, with spokes) on a dark rounded square. Drawn in a `Canvas` so it
/// stays crisp at any size and matches the Dock icon.
struct BrandMark: View {
    var size: CGFloat = 22

    private static let bgTop    = Color(red: 34/255, green: 28/255, blue: 24/255)
    private static let bgBottom = Color(red: 17/255, green: 14/255, blue: 11/255)
    private static let cream    = Color(red: 244/255, green: 222/255, blue: 202/255)
    private static let glowCol  = Color(red: 217/255, green: 119/255, blue: 87/255)

    var body: some View {
        Canvas { ctx, sz in
            let S = min(sz.width, sz.height)
            let bg = Path(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                          cornerRadius: S * 0.28, style: .continuous)
            ctx.fill(bg, with: .linearGradient(
                Gradient(colors: [Self.bgTop, Self.bgBottom]),
                startPoint: CGPoint(x: S/2, y: 0), endPoint: CGPoint(x: S/2, y: S)))
            ctx.clip(to: bg)

            let c = CGPoint(x: S/2, y: S/2)
            let R = S * 0.305
            let nodeR = S * 0.055
            let centerR = S * 0.088
            let lw = max(0.6, S * 0.024)
            let pts = (0..<8).map { i -> CGPoint in
                let a = -CGFloat.pi/2 + CGFloat(i) * (.pi/4)   // node at top, every 45°
                return CGPoint(x: c.x + R*cos(a), y: c.y + R*sin(a))
            }

            ctx.addFilter(.shadow(color: Self.glowCol.opacity(0.9), radius: S * 0.04))

            var net = Path()
            net.addEllipse(in: CGRect(x: c.x-R, y: c.y-R, width: 2*R, height: 2*R))
            for p in pts { net.move(to: c); net.addLine(to: p) }
            ctx.stroke(net, with: .color(Self.cream), lineWidth: lw)

            for p in pts {
                let r = CGRect(x: p.x-nodeR, y: p.y-nodeR, width: 2*nodeR, height: 2*nodeR)
                ctx.fill(Path(ellipseIn: r), with: .color(Color.atelierAccent))
                ctx.stroke(Path(ellipseIn: r), with: .color(Self.cream), lineWidth: lw * 0.8)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x-centerR, y: c.y-centerR,
                                            width: 2*centerR, height: 2*centerR)),
                     with: .color(Self.cream))
        }
        .frame(width: size, height: size)
        .shadow(color: Color.atelierAccent.opacity(0.25), radius: size * 0.18, x: 0, y: size * 0.05)
    }
}
