// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct ControllerSettingsView: View {
    @State private var settings = SettingsStore.shared
    @State private var focus = TileFocus.shared
    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private var navigationSections: [[String]] {
        [
            ["controller.haptic", "controller.opacity", "theme.vpadColor", "theme.vpadStrokeColor", "theme.vpadStrokeWidth"],
            ["controller.rumble", "controller.phoneFallback", "controller.rumbleIntensity"],
            PhysicalControllerButtonMappingPanel.mappingTileIDsForFocus,
            ["controller.reset"],
        ]
    }

    var body: some View {
        ZStack {
            SettingsScroll {
                SettingSection(title: SakuraL10n.tr("controller.settings.section.ports")) {
                    ControllerPortsPanel()
                }

                SettingSection(title: SakuraL10n.tr("controller.settings.section.touch")) {
                    TileGrid {
                        ToggleTile(
                            id: "controller.haptic",
                            icon: "waveform",
                            title: SakuraL10n.tr("controller.touch.hapticShort"),
                            isOn: $settings.hapticFeedback
                        )
                        opacityTile
                        ColorSwatchGrid(
                            title: SakuraL10n.tr("controller.padColorTile"),
                            icon: "circle.fill",
                            selectedKey: Binding(
                                get: { theme.vpadColorKey },
                                set: { theme.vpadColorKey = $0 }
                            ),
                            id: "theme.vpadColor"
                        )
                        ColorSwatchGrid(
                            title: SakuraL10n.tr("controller.strokeColorTile"),
                            icon: "circle",
                            selectedKey: Binding(
                                get: { theme.vpadStrokeColorKey },
                                set: { theme.vpadStrokeColorKey = $0 }
                            ),
                            id: "theme.vpadStrokeColor"
                        )
                        SliderTile(
                            id: "theme.vpadStrokeWidth",
                            icon: "line.diagonal",
                            title: SakuraL10n.tr("controller.strokeWidthTile"),
                            value: Binding(
                                get: { theme.vpadStrokeWidth },
                                set: { theme.vpadStrokeWidth = $0 }
                            ),
                            range: 0...3,
                            step: 0.1,
                            format: { String(format: "%.1f", $0) }
                        )
                    }
                }

                SettingSection(title: SakuraL10n.tr("controller.section.vibration")) {
                    TileGrid {
                        ToggleTile(
                            id: "controller.rumble",
                            icon: "iphone.radiowaves.left.and.right",
                            title: SakuraL10n.tr("controller.tile.rumbleTile"),
                            isOn: $settings.controllerRumbleEnabled
                        )
                        ToggleTile(
                            id: "controller.phoneFallback",
                            icon: "iphone.gen3.radiowaves.left.and.right",
                            title: SakuraL10n.tr("controller.tile.phoneFallback"),
                            isOn: $settings.phoneVibrationFallback
                        )
                        rumbleIntensityTile
                    }
                }

                SettingSection(title: SakuraL10n.tr("controller.section.consmenu")) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(0.9))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(SakuraL10n.tr("controller.consmenu.openWithHeading"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.glassTextPrimary(colorScheme))
                            Text(EmuMenuComboStorage.displayLabel())
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.accentColor())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(theme.glassTileBackground(colorScheme, isFocused: false))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(theme.glassTileStroke(colorScheme, isFocused: false), lineWidth: 1)
                    )
                }

                PhysicalControllerButtonMappingPanel()
            }
        }
        .onAppear {
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
    }

    private var opacityTile: some View {
        let tileID = "controller.opacity"
        let isFocused = focus.focusedID == tileID && focus.region == .content
        let nudgeUp: () -> Void = {
            let stepped = (settings.padOpacity + 0.1).rounded(.down)
            settings.padOpacity = stepped > 1.0 ? 0.1 : max(0.1, stepped)
            SFXManager.shared.play(.toggle)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(0.9))
                Spacer(minLength: 0)
                Text("\(Int(settings.padOpacity * 100))%")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
            }

            Spacer(minLength: 0)

            Text(SakuraL10n.tr("controller.opacityLabelCaps"))
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(theme.glassTextTertiary(colorScheme))

            Slider(value: $settings.padOpacity, in: 0.1...1.0, step: 0.05)
                .tint(theme.accentColor())
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.glassTileBackground(colorScheme, isFocused: isFocused))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    theme.glassTileStroke(colorScheme, isFocused: isFocused),
                    lineWidth: isFocused ? 2.5 : 1
                )
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .contentShape(Rectangle())
        .onTapGesture {
            focus.focusFromTouch(id: tileID)
            nudgeUp()
        }
        .background(TileColumnReporter(id: tileID))
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == tileID && focus.region == .content {
                nudgeUp()
            }
        }
        .id(tileID)
    }

    private var rumbleIntensityTile: some View {
        let tileID = "controller.rumbleIntensity"
        let isFocused = focus.focusedID == tileID && focus.region == .content
        let nudgeUp: () -> Void = {
            let stepped = (settings.controllerRumbleIntensity + 0.2)
            settings.controllerRumbleIntensity = stepped > 2.0 ? 0.0 : stepped
            SFXManager.shared.play(.toggle)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: "dial.low")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(0.9))
                Spacer(minLength: 0)
                Text("\(Int(settings.controllerRumbleIntensity * 100))%")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
            }

            Spacer(minLength: 0)

            Text(SakuraL10n.tr("controller.intensityLabelCaps"))
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(theme.glassTextTertiary(colorScheme))

            Slider(value: $settings.controllerRumbleIntensity, in: 0.0...2.0, step: 0.1)
                .tint(theme.accentColor())
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.glassTileBackground(colorScheme, isFocused: isFocused))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    theme.glassTileStroke(colorScheme, isFocused: isFocused),
                    lineWidth: isFocused ? 2.5 : 1
                )
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .contentShape(Rectangle())
        .onTapGesture {
            focus.focusFromTouch(id: tileID)
            nudgeUp()
        }
        .background(TileColumnReporter(id: tileID))
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == tileID && focus.region == .content {
                nudgeUp()
            }
        }
        .id(tileID)
    }
}
