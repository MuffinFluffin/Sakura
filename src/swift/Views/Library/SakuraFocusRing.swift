// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

/// Unified focus indicator used everywhere in the shell (covers, save chips, top-bar
/// tabs, media tiles, AirConsole tiles). Single visual language so the user always
/// knows what is selected without having to learn one ring per region.
///
/// Stacks on top of the host view's own background/stroke - it is purely additive:
/// when `isFocused` is false it draws nothing.
struct SakuraFocusRing: ViewModifier {
    let isFocused: Bool
    let controllerActive: Bool
    var cornerRadius: CGFloat = 12
    var inset: CGFloat = 0
    /// Use the heavier AirConsole / external-display treatment: thicker stroke,
    /// stronger accent glow, double-line outer ring, and a subtle pulse so the
    /// selection is unmistakable from across the room.
    var tvMode: Bool = false

    @State private var theme = ThemeManager.shared
    @State private var pulse: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { theme.accentColor() }

    private var ringStrokeWidth: CGFloat {
        if !isFocused { return 0 }
        if tvMode {
            if theme.highContrastOutlines { return 7 }
            if theme.increaseContrast { return 6 }
            return 5
        }
        if theme.highContrastOutlines { return controllerActive ? 4 : 3 }
        if theme.increaseContrast { return controllerActive ? 3.5 : 2.6 }
        return controllerActive ? 3 : 2
    }

    private var glowRadius: CGFloat {
        guard isFocused else { return 0 }
        if theme.materialsReduced { return 0 }
        if tvMode { return pulse ? 32 : 22 }
        return controllerActive ? 16 : 8
    }

    private var glowOpacity: Double {
        guard isFocused else { return 0 }
        if theme.materialsReduced { return 0 }
        if tvMode { return colorScheme == .light ? 0.7 : 0.85 }
        if colorScheme == .light { return controllerActive ? 0.45 : 0.28 }
        return controllerActive ? 0.6 : 0.38
    }

    private var innerHighlightOpacity: Double {
        guard isFocused else { return 0 }
        if tvMode { return 0.85 }
        return controllerActive ? 0.55 : 0.32
    }

    private var scale: CGFloat {
        guard isFocused else { return 1.0 }
        if theme.reduceMotion { return 1.0 }
        if tvMode { return 1.06 }
        return controllerActive ? 1.04 : 1.02
    }

    private var dimUnfocused: Double {
        // When TV mode is on but THIS specific instance is unfocused, the parent
        // can layer multiple unfocused-tile dimming on top, we don't dim here so
        // siblings stay readable. The carousel handles its own dimming.
        1.0
    }

    func body(content: Content) -> some View {
        content
            .shadow(
                color: accent.opacity(glowOpacity),
                radius: glowRadius,
                x: 0,
                y: 0
            )
            .overlay {
                if isFocused {
                    ZStack {
                        if tvMode {
                            RoundedRectangle(cornerRadius: cornerRadius + 6, style: .continuous)
                                .inset(by: inset - 5)
                                .stroke(accent.opacity(pulse ? 0.55 : 0.85), lineWidth: ringStrokeWidth + 2)
                                .blur(radius: 1.5)
                        }
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .inset(by: inset)
                            .stroke(accent, lineWidth: ringStrokeWidth)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .inset(by: inset + ringStrokeWidth + 0.5)
                            .stroke(.white.opacity(innerHighlightOpacity), lineWidth: tvMode ? 1.4 : 0.75)
                    }
                    .allowsHitTesting(false)
                }
            }
            .scaleEffect(scale)
            .opacity(dimUnfocused)
            .animation(theme.libraryCardScaleAnimation, value: isFocused)
            .animation(theme.libraryCardScaleAnimation, value: controllerActive)
            .onAppear {
                if tvMode, !theme.reduceMotion {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            }
    }
}

extension View {
    // apply the standard Sakura focus ring. set controllerActive only when the
    // gamepad / keyboard / external display is the input source. touch focus uses
    // a softer treatment so the user is not yelled at when tapping the phone.
    func sakuraFocusRing(
        isFocused: Bool,
        controllerActive: Bool = true,
        cornerRadius: CGFloat = 12,
        inset: CGFloat = 0,
        tvMode: Bool = false
    ) -> some View {
        modifier(
            SakuraFocusRing(
                isFocused: isFocused,
                controllerActive: controllerActive,
                cornerRadius: cornerRadius,
                inset: inset,
                tvMode: tvMode
            )
        )
    }
}
