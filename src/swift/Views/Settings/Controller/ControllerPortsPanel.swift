// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import GameController

struct ControllerPortsPanel: View {
    @Bindable private var theme = ThemeManager.shared
    @ObservedObject private var assigner = ControllerPortAssigner.shared
    @State private var allPads: [GCController] = []
    @State private var modeRefresh: Int = 0

    private var bubbleFill: Color {
        theme.inGameMenuBubbleColor().opacity(min(0.48, max(0.04, theme.inGameMenuBubbleFillOpacity)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                portRow(port: 0)
                divider()
                portRow(port: 1)
                divider()
                touchNoteRow()
                divider()
                autoSwitchRow()
            }
            .padding(6)
            .background(bubbleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 12)
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .sakuraControllerPortAssignmentsChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SakuraPS1ControllerModeChanged"))) { _ in
            modeRefresh &+= 1
        }
        .onAppear { refresh() }
    }

    private func divider() -> some View {
        Rectangle()
            .fill(theme.inGameMenuTextColor().opacity(0.06))
            .frame(height: 1)
            .padding(.horizontal, 8)
    }

    private func refresh() {
        allPads = assigner.connectedPhysicalControllers()
    }

    private func portRow(port: Int) -> some View {
        let live = assigner.liveByPort[port]
        let label: String
        if let live, let v = live.vendorName {
            label = v
        } else if port == 0 {
            label = SakuraL10n.tr("emu.controllerPopup.touchPad")
        } else {
            label = SakuraL10n.tr("emu.controllerPopup.empty")
        }
        let _ = modeRefresh
        let modeBinding = Binding<Int>(
            get: { Int(SakuraBridge.ps1ControllerMode(forPort: Int32(port))) },
            set: { SakuraBridge.setPS1ControllerMode(Int32($0), forPort: Int32(port)) }
        )

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: port == 0 ? "1.circle.fill" : "2.circle.fill")
                    .font(.system(size: 20))
                    .frame(width: 22, alignment: .center)
                    .foregroundStyle(theme.inGameMenuIconColor())
                Text(SakuraL10n.trf("emu.controllerPopup.portFmt", port + 1))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.inGameMenuTextColor())
                Spacer(minLength: 6)
                assignmentPicker(port: port, fallbackLabel: label)
            }
            HStack(spacing: 8) {
                Picker("", selection: modeBinding) {
                    Text(SakuraL10n.tr("accessibilityEmu.controllerDigital")).tag(0)
                    Text(SakuraL10n.tr("accessibilityEmu.controllerDualShock")).tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.leading, 30)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
                refresh()
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
        .font(.system(size: 12))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityLabel(fallbackLabel)
    }

    private func padPickerLabel(_ pad: GCController) -> String {
        let name = pad.vendorName ?? pad.productCategory
        if let p = assigner.port(for: pad) {
            return SakuraL10n.trf("controller.settings.port.padAssignedFmt", name, p + 1)
        }
        return name
    }

    private func touchNoteRow() -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 16))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(theme.inGameMenuIconColor())
            Text(SakuraL10n.tr("controller.settings.touchLockedNote"))
                .font(.system(size: 12))
                .foregroundStyle(theme.inGameMenuCaptionColor().opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func autoSwitchRow() -> some View {
        let binding = Binding<Bool>(
            get: { SettingsStore.shared.controllerAutoSwitch },
            set: { SettingsStore.shared.controllerAutoSwitch = $0 }
        )
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(theme.inGameMenuIconColor())
            Text(SakuraL10n.tr("controller.tile.analogAutoSwitch"))
                .font(.system(size: 14))
                .foregroundStyle(theme.inGameMenuTextColor())
            Spacer(minLength: 4)
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(theme.inGameMenuControlAccent())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
