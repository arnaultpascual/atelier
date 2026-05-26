// SPDX-License-Identifier: MIT
import SwiftUI

/// Shared UI building blocks derived from `DesignSystem.swift` tokens. These replace
/// the inline recipes (hairline dividers, section labels, warning blocks, card shells)
/// that had drifted across the app, so a restyle happens in one place.

// MARK: - Section label

/// The "eyebrow caps in secondary ink" label used above form fields and section groups.
/// Was an inline `Text(..).font(AtelierFont.eyebrow).foregroundStyle(.atelierInkSecondary)`
/// repeated dozens of times.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(AtelierFont.eyebrow)
            .foregroundStyle(Color.atelierInkSecondary)
    }
}

// MARK: - Section header

/// A page/section header: serif title + optional caption subtitle. Replaces the per-file private
/// `sectionHeader(_:subtitle:)` helpers (SettingsView, SkillsTab) so Settings surfaces match.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(Color.atelierInk)
            if let subtitle {
                Text(subtitle)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
        }
    }
}

// MARK: - Hairline divider

/// The horizontal hairline used between sections. Was an inline
/// `Rectangle().fill(Color.atelierDivider.opacity(0.6)).frame(height: 1)` in ~20 places.
struct AtelierDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.atelierDivider.opacity(0.6))
            .frame(height: 1)
    }
}

// MARK: - Callout banner

/// A single, consistent inline notice for info / warning / danger — replaces the
/// hand-rolled "icon + tinted text (± soft background)" blocks that each used slightly
/// different paddings, radii, and colors.
struct CalloutBanner: View {
    enum Style { case info, warning, danger }

    let style: Style
    let text: String
    var icon: String?

    init(_ style: Style, _ text: String, icon: String? = nil) {
        self.style = style
        self.text = text
        self.icon = icon
    }

    private var tint: Color {
        switch style {
        case .info: return Color.atelierAccent
        case .warning: return Palette.warning
        case .danger: return Palette.error
        }
    }
    private var defaultIcon: String {
        switch style {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon ?? defaultIcon)
                .font(.system(size: 10))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(AtelierFont.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AtelierCorner.control))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(tint.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Card surface

/// Atelier's standard card shell: a filled, rounded surface with a hairline border.
/// Replaces the repeated `.background(fill, in: RoundedRectangle(r)).overlay(RoundedRectangle(r).stroke(border))`
/// pair. `fill`/`border`/`borderWidth` are parameters so stateful cards (selection, hover,
/// agent-state) keep their own logic; defaults give the canonical opaque-surface card.
/// Padding stays with the caller (some cards pad inner content, not the whole shell).
struct AtelierCardModifier: ViewModifier {
    var cornerRadius: CGFloat = AtelierCorner.card
    var fill: Color = .atelierSurface
    var border: Color = .atelierDivider
    var borderWidth: CGFloat = 1
    /// When true, the card reads as *selected* via a soft accent fill — distinct from any
    /// state expressed on the border (so "selected" and "running" never collide).
    var selected: Bool = false

    func body(content: Content) -> some View {
        content
            .background(selected ? Color.atelierAccent.opacity(0.10) : fill,
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(border, lineWidth: borderWidth))
    }
}

extension View {
    /// Wrap a view in Atelier's standard card surface (fill + rounded shape + hairline border).
    func atelierCard(cornerRadius: CGFloat = AtelierCorner.card,
                     fill: Color = .atelierSurface,
                     border: Color = .atelierDivider,
                     borderWidth: CGFloat = 1,
                     selected: Bool = false) -> some View {
        modifier(AtelierCardModifier(cornerRadius: cornerRadius, fill: fill, border: border,
                                     borderWidth: borderWidth, selected: selected))
    }
}

// MARK: - Dependency chip

/// Compact "depends on N" marker shown on cards so dependency structure is visible without
/// opening the task. Quiet (ink-secondary outline) — it's metadata, not an action.
struct DependencyChip: View {
    let count: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
            Text("\(count)").font(AtelierFont.eyebrow)
        }
        .foregroundStyle(Color.atelierInkSecondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.atelierSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
        .help("Depends on \(count) task\(count == 1 ? "" : "s")")
    }
}
