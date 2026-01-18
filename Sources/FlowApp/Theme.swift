//
// Theme.swift
// Flow
//
// Swedish minimalism design system. Adapts to light/dark mode.
//

import AppKit
import SwiftUI

// MARK: - Window Size

enum WindowSize {
    static var screen: CGRect { NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
    static var width: CGFloat { screen.width * 0.7 }
    static var height: CGFloat { screen.height * 0.7 }
    static let minWidth: CGFloat = 700
    static let minHeight: CGFloat = 500
}

// MARK: - Design System

enum FW {
    // MARK: - Colors (Adaptive Light/Dark)

    /// Background - adapts to system appearance
    static let background = Color(nsColor: .init(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.067, green: 0.067, blue: 0.075, alpha: 1) // #111113
                : NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)    // #FAFAFA
        }
    ))

    /// Elevated surface for cards
    static let surface = Color(nsColor: .init(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 1)   // #1C1C1E
                : NSColor(red: 1, green: 1, blue: 1, alpha: 1)             // #FFFFFF
        }
    ))

    /// Subtle border/divider
    static let border = Color(nsColor: .init(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.2, green: 0.2, blue: 0.21, alpha: 1)      // #333336
                : NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)       // #E5E5E5
        }
    ))

    /// Primary text
    static let textPrimary = Color(nsColor: .init(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)    // #FAFAFA
                : NSColor(red: 0.067, green: 0.067, blue: 0.075, alpha: 1) // #111113
        }
    ))

    /// Secondary text
    static let textSecondary = Color(nsColor: .init(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.63, green: 0.63, blue: 0.65, alpha: 1)    // #A1A1A6
                : NSColor(red: 0.4, green: 0.4, blue: 0.42, alpha: 1)      // #66666B
        }
    ))

    /// Muted/tertiary text
    static let textMuted = Color(nsColor: .init(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.45, green: 0.45, blue: 0.47, alpha: 1)    // #737378
                : NSColor(red: 0.55, green: 0.55, blue: 0.57, alpha: 1)    // #8C8C91
        }
    ))

    /// Primary accent - indigo
    static let accent = Color(red: 0.388, green: 0.4, blue: 0.945) // #6366F1

    /// Hover/active state - indigo darker
    static let accentMuted = Color(red: 0.31, green: 0.275, blue: 0.898) // #4F46E5

    /// Recording/danger state - red
    static let danger = Color(red: 0.937, green: 0.267, blue: 0.267) // #EF4444

    /// Success/configured state - green
    static let success = Color(red: 0.133, green: 0.773, blue: 0.369) // #22C55E

    /// Warning state - amber
    static let warning = Color(red: 0.95, green: 0.65, blue: 0.15)

    // Legacy aliases
    static var recording: Color { danger }
    static var surfacePrimary: Color { background }
    static var surfaceElevated: Color { surface }
    static var textTertiary: Color { textMuted }
    static var accentSecondary: Color { accentMuted }

    // MARK: - Spacing

    static let spacing2: CGFloat = 2
    static let spacing4: CGFloat = 4
    static let spacing6: CGFloat = 6
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32

    // MARK: - Radii

    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16
    static let radiusXL: CGFloat = 24

    // MARK: - Typography

    static let fontMono = Font.system(.body, design: .monospaced)
    static let fontMonoSmall = Font.system(.caption, design: .monospaced)
    static let fontMonoLarge = Font.system(.title3, design: .monospaced).weight(.medium)
}

// MARK: - View Extensions

extension View {
    /// Modern card with subtle border
    func fwCard() -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: FW.radiusMedium)
                    .fill(FW.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: FW.radiusMedium)
                            .strokeBorder(FW.border, lineWidth: 1)
                    }
            }
    }

    /// Section card with minimal styling
    func fwSection() -> some View {
        self
            .padding(FW.spacing20)
            .background {
                RoundedRectangle(cornerRadius: FW.radiusMedium)
                    .fill(FW.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: FW.radiusMedium)
                            .strokeBorder(FW.border, lineWidth: 1)
                    }
            }
    }

    /// Section header style (uppercase, muted, small)
    func fwSectionHeader() -> some View {
        self
            .font(.caption.weight(.semibold))
            .foregroundStyle(FW.textMuted)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

// MARK: - Button Styles

struct FWPrimaryButtonStyle: ButtonStyle {
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, FW.spacing20)
            .padding(.vertical, FW.spacing12)
            .background {
                RoundedRectangle(cornerRadius: FW.radiusSmall)
                    .fill(isDestructive ? FW.danger : FW.accent)
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct FWSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(FW.accent)
            .padding(.horizontal, FW.spacing12)
            .padding(.vertical, FW.spacing8)
            .background {
                RoundedRectangle(cornerRadius: FW.radiusSmall)
                    .fill(FW.accent.opacity(configuration.isPressed ? 0.15 : 0.1))
            }
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct FWGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(configuration.isPressed ? FW.textMuted : FW.textSecondary)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Form Row Component

struct FWFormRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(FW.textPrimary)

            Spacer()

            content
        }
    }
}
