// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct ColorSwatchGrid: View {
    let title: String
    let icon: String
    @Binding var selectedKey: String
    var id: String

    @State private var theme = ThemeManager.shared
    @State private var focus = TileFocus.shared
    @State private var showPicker = false
    @Environment(\.colorScheme) private var colorScheme

    private var isFocused: Bool {
        focus.focusedID == id && focus.region == .content
    }

    private var tileMinHeight: CGFloat {
        theme.largerTouchTargets ? 140 : 112
    }

    private var tileBgOpacity: Double {
        if theme.reduceTransparency {
            return isFocused ? 0.45 : 0.30
        }
        return isFocused ? 0.16 : 0.08
    }

    private var strokeColor: Color {
        if theme.highContrastOutlines {
            return isFocused ? .white : .white.opacity(0.5)
        }
        if theme.increaseContrast {
            return isFocused ? .white : .white.opacity(0.3)
        }
        return isFocused ? .white : .white.opacity(0.12)
    }

    private var strokeWidth: CGFloat {
        if theme.highContrastOutlines {
            return isFocused ? 3 : 2
        }
        if theme.increaseContrast {
            return isFocused ? 3 : 1.5
        }
        return isFocused ? 2.5 : 1
    }


    var body: some View {
        Button {
            focus.focusFromTouch(id: id)
            SFXManager.shared.play(.confirm)
            advance()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(0.9))
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.color(forKey: selectedKey))
                        .frame(width: 18, height: 18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(theme.glassTextPrimary(colorScheme).opacity(0.35), lineWidth: 0.5)
                        )
                }

                Spacer(minLength: 0)

                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(currentSwatchName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: tileMinHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .fill(theme.glassTileBackground(colorScheme, isFocused: isFocused))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
            .shadow(
                color: isFocused ? theme.glassTileShadow(colorScheme, isFocused: true) : .clear,
                radius: isFocused ? 10 : 0
            )
            .compositingGroup()
            .scaleEffect(isFocused && !theme.reduceMotion ? 1.02 : 1.0)
            .animation(
                theme.reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.7),
                value: isFocused
            )
        }
        .buttonStyle(.plain)
        .id(id)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                focus.focusFromTouch(id: id)
                showPicker = true
            }
        )
        .accessibilityLabel("\(title), \(currentSwatchName)")
        .accessibilityHint(SakuraL10n.tr("accessibility.palette.cycleHint"))
        .background(TileColumnReporter(id: id))
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == id && focus.region == .content {
                SFXManager.shared.play(.confirm)
                advance()
            }
        }
        .sheet(isPresented: $showPicker) {
            PalettePickerSheet(
                title: title,
                selectedKey: $selectedKey
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }


    private func advance() {
        let palette = ThemeManager.palette
        guard !palette.isEmpty else { return }
        let idx = palette.firstIndex(where: { $0.key == selectedKey }) ?? -1
        selectedKey = palette[(idx + 1) % palette.count].key
    }

    private var currentSwatchName: String {
        guard let s = ThemeManager.palette.first(where: { $0.key == selectedKey }) else {
            return SakuraL10n.tr("common.emdash")
        }
        return localizedPaletteName(key: s.key, englishFallback: s.name)
    }

    private func localizedPaletteName(key: String, englishFallback: String) -> String {
        let lk = "theme.palette.\(key)"
        let t = SakuraL10n.tr(lk)
        return t != lk ? t : englishFallback
    }
}


private struct PalettePickerSheet: View {
    let title: String
    @Binding var selectedKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var theme = ThemeManager.shared

    private let swatchSize: CGFloat = 36

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: swatchSize + 8), spacing: 10)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(ThemeManager.palette) { swatch in
                        swatchButton(swatch)
                    }
                }
                .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(SakuraL10n.tr("common.done")) { dismiss() }
                }
            }
        }
    }

    private func swatchButton(_ swatch: ThemeSwatch) -> some View {
        let selected = swatch.key == selectedKey
        return Button {
            selectedKey = swatch.key
            SFXManager.shared.play(.confirm)
            dismiss()
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(swatch.color)
                    .frame(width: swatchSize, height: swatchSize)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                selected ? Color.white : Color.white.opacity(0.2),
                                lineWidth: selected ? 2.5 : 1
                            )
                    )
                    .overlay(alignment: .center) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.7), radius: 1)
                        }
                    }
                Text(localizedPaletteName(key: swatch.key, englishFallback: swatch.name))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localizedPaletteName(key: swatch.key, englishFallback: swatch.name))
    }

    private func localizedPaletteName(key: String, englishFallback: String) -> String {
        let lk = "theme.palette.\(key)"
        let t = SakuraL10n.tr(lk)
        return t != lk ? t : englishFallback
    }
}
