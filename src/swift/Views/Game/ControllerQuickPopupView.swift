// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import GameController

struct ControllerQuickPopupView: View {
    @Binding var isPresented: Bool
    @Bindable private var theme = ThemeManager.shared
    @ObservedObject private var assigner = ControllerPortAssigner.shared
    @State private var modes: [Int] = [0, 0]
    @State private var allPads: [GCController] = []

    private var bootKey: String { SakuraBridge.currentISOPath() ?? "" }

    private var bubbleFill: Color {
        theme.inGameMenuBubbleColor().opacity(min(0.48, max(0.04, theme.inGameMenuBubbleFillOpacity)))
    }

    private var bodyFont: CGFloat { 14 }

    private var panelWidth: CGFloat {
        let w = UIScreen.main.bounds.width
        return min(440, max(280, w - 96))
    }

    private var scrollMaxHeight: CGFloat {
        min(380, UIScreen.main.bounds.height * 0.42)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(SakuraL10n.tr("emu.controllerPopup.title"))
                    .font(.system(size: bodyFont + 2, weight: .semibold))
                    .foregroundStyle(theme.inGameMenuHeaderColor().opacity(0.96))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    section(port: 0)
                    section(port: 1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: scrollMaxHeight)
        }
        .frame(width: panelWidth)
        .modifier(PopupSurface())
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sakuraControllerPortAssignmentsChanged)) { _ in reload() }
    }

    private func reload() {
        allPads = assigner.connectedPhysicalControllers()
        modes[0] = Int(SakuraBridge.ps1ControllerMode(forGame: bootKey, port: 0))
        modes[1] = Int(SakuraBridge.ps1ControllerMode(forGame: bootKey, port: 1))
    }

    private func section(port: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(port: port)
            VStack(alignment: .leading, spacing: 0) {
                padRow(port: port)
                divider()
                modeRow(port: port)
            }
            .padding(6)
            .background(bubbleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func sectionHeader(port: Int) -> some View {
        Text(SakuraL10n.trf("emu.controllerPopup.portFmt", port + 1))
            .font(.system(size: bodyFont - 1, weight: .semibold))
            .foregroundStyle(theme.inGameMenuHeaderColor().opacity(0.96))
            .padding(.top, 0)
            .padding(.bottom, 2)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(theme.inGameMenuTextColor().opacity(0.06))
            .frame(height: 1)
            .padding(.horizontal, 4)
    }

    private func padRow(port: Int) -> some View {
        let live = assigner.liveByPort[port]
        let label: String
        if let live, let v = live.vendorName {
            label = v
        } else if port == 0 {
            label = SakuraL10n.tr("emu.controllerPopup.touchPad")
        } else {
            label = SakuraL10n.tr("emu.controllerPopup.empty")
        }

        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: bodyFont + 4))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(theme.inGameMenuIconColor())
            Text(SakuraL10n.tr("controller.settings.port.padLabel"))
                .font(.system(size: bodyFont))
                .foregroundStyle(theme.inGameMenuTextColor())
            Spacer(minLength: 6)
            assignmentPicker(port: port, fallbackLabel: label)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func assignmentPicker(port: Int, fallbackLabel: String) -> some View {
        let noneTag = -1
        let binding = Binding<Int>(
            get: {
                guard let live = assigner.liveByPort[port] else { return noneTag }
                return allPads.firstIndex(where: { $0 === live }) ?? noneTag
            },
            set: { tag in
                if tag == noneTag {
                    assigner.clear(port: port)
                } else if allPads.indices.contains(tag) {
                    assigner.reassign(controller: allPads[tag], to: port)
                }
                reload()
            }
        )
        return Picker("", selection: binding) {
            Text(port == 0 ? SakuraL10n.tr("emu.controllerPopup.touchPad") : SakuraL10n.tr("emu.controllerPopup.empty"))
                .tag(noneTag)
            ForEach(Array(allPads.enumerated()), id: \.offset) { index, pad in
                Text(padPickerLabel(pad))
                    .tag(index)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(theme.accentColor())
        .font(.system(size: bodyFont - 1))
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(0.7)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 200, alignment: .trailing)
        .accessibilityLabel(fallbackLabel)
    }

    private func modeRow(port: Int) -> some View {
        let binding = Binding<Int>(
            get: { modes[port] },
            set: { newValue in
                modes[port] = newValue
                SakuraBridge.setPS1ControllerModeForCurrentISOOrGlobal(Int32(newValue), port: Int32(port))
            }
        )
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "dpad.fill")
                .font(.system(size: bodyFont + 4))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(theme.inGameMenuIconColor())
            Text(SakuraL10n.tr("emu.menu.controllerPicker"))
                .font(.system(size: bodyFont))
                .foregroundStyle(theme.inGameMenuTextColor())
            Spacer(minLength: 6)
            Picker("", selection: binding) {
                Text(SakuraL10n.tr("emu.menu.padDigital")).tag(0)
                Text(SakuraL10n.tr("emu.menu.padDualShock")).tag(1)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(theme.accentColor())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func padPickerLabel(_ pad: GCController) -> String {
        let name = pad.vendorName ?? pad.productCategory
        if let p = assigner.port(for: pad) {
            return SakuraL10n.trf("controller.settings.port.padAssignedFmt", name, p + 1)
        }
        return name
    }
}

private struct PopupSurface: ViewModifier {
    @Bindable private var chrome = ThemeManager.shared

    func body(content: Content) -> some View {
        let radius = chrome.boxyCorners ? max(8, chrome.inGameMenuCornerRadius - 6) : chrome.inGameMenuCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(
                Group {
                    if chrome.inGameMenuUsesLiteChrome {
                        Color.black.opacity(chrome.inGameMenuScrimOpacity)
                    } else if chrome.materialsReduced {
                        Color.black.opacity(0.84)
                    } else {
                        Color.clear.background(.ultraThinMaterial)
                    }
                }
            )
            .clipShape(shape)
            .overlay(
                shape.stroke(
                    chrome.inGameMenuOuterStrokeColor().opacity(chrome.inGameMenuStrokeOpacity),
                    lineWidth: chrome.inGameMenuStrokeWidth
                )
            )
            .shadow(
                color: .black.opacity(chrome.inGameMenuUsesLiteChrome ? 0.18 : 0.1),
                radius: chrome.inGameMenuShadowRadius, x: 0, y: 6
            )
    }
}
