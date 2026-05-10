// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

private struct PadMapButton: Identifiable {
    let id: Int
    let nameKey: String
    let iconName: String?
}

private let padMapButtons: [PadMapButton] = [
    PadMapButton(id: 0, nameKey: "controller.map.dpad.up", iconName: "arrowtriangle.up.fill"),
    PadMapButton(id: 1, nameKey: "controller.map.dpad.down", iconName: "arrowtriangle.down.fill"),
    PadMapButton(id: 2, nameKey: "controller.map.dpad.left", iconName: "arrowtriangle.left.fill"),
    PadMapButton(id: 3, nameKey: "controller.map.dpad.right", iconName: "arrowtriangle.right.fill"),
    PadMapButton(id: 4, nameKey: "controller.map.face.crossSymbol", iconName: "multiply"),
    PadMapButton(id: 5, nameKey: "controller.map.face.circle", iconName: "circle"),
    PadMapButton(id: 6, nameKey: "controller.map.face.square", iconName: "square"),
    PadMapButton(id: 7, nameKey: "controller.map.face.triangleSymbol", iconName: "triangle"),
    PadMapButton(id: 8, nameKey: "controller.map.face.l1", iconName: "l1.button.roundedbottom.horizontal"),
    PadMapButton(id: 9, nameKey: "controller.map.face.r1", iconName: "r1.button.roundedbottom.horizontal"),
    PadMapButton(id: 12, nameKey: "controller.map.face.startBtn", iconName: "line.3.horizontal"),
    PadMapButton(id: 13, nameKey: "controller.map.face.selectBtn", iconName: "rectangle.on.rectangle"),
    PadMapButton(id: 14, nameKey: "controller.map.face.l3", iconName: "l.joystick.press.down"),
    PadMapButton(id: 15, nameKey: "controller.map.face.r3", iconName: "r.joystick.press.down"),
]

private func localizedGamepadButtonName(_ idx: Int) -> String {
    switch idx {
    case 0: return SakuraL10n.tr("controller.gc.aCrossHybrid")
    case 1: return SakuraL10n.tr("controller.gc.bCircleHybrid")
    case 2: return SakuraL10n.tr("controller.gc.xSquareHybrid")
    case 3: return SakuraL10n.tr("controller.gc.yTriangleHybrid")
    case 4: return SakuraL10n.tr("controller.sdl.shareBack")
    case 5: return SakuraL10n.tr("controller.sdl.guidePs")
    case 6: return SakuraL10n.tr("controller.sdl.optionsStart")
    case 7: return SakuraL10n.tr("controller.gc.lStickPress")
    case 8: return SakuraL10n.tr("controller.gc.rStickPress")
    case 9: return SakuraL10n.tr("controller.sdl.lShoulder")
    case 10: return SakuraL10n.tr("controller.sdl.rShoulder")
    case 11: return SakuraL10n.tr("controller.gc.dpad.up")
    case 12: return SakuraL10n.tr("controller.gc.dpad.down")
    case 13: return SakuraL10n.tr("controller.gc.dpad.left")
    case 14: return SakuraL10n.tr("controller.gc.dpad.right")
    case 15: return SakuraL10n.tr("controller.sdl.miscShare")
    case 20: return SakuraL10n.tr("controller.sdl.touchpad")
    default: return SakuraL10n.trf("controller.gc.buttonFmt", idx)
    }
}

let sakuraPhysicalMappingCapturedNotifName = Notification.Name("SakuraPhysicalCaptureMappedControllerSettings")

struct PhysicalControllerButtonMappingPanel: View {
    @State private var focus = TileFocus.shared
    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var capturingIndex: Int? = nil
    @State private var mappingVersion = 0
    @State private var pollTimer: Timer? = nil

    static func mappingID(for buttonID: Int) -> String { "controller.map.\(buttonID)" }

    static var mappingTileIDsForFocus: [String] {
        padMapButtons.map { mappingID(for: $0.id) }
    }

    static var focusPageSectionsForStandaloneSheet: [[String]] {
        [mappingTileIDsForFocus, ["controller.reset"]]
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                SettingSection(title: SakuraL10n.tr("controller.mapping.sectionExternal")) {
                    TileGrid(minTileWidth: 148) {
                        ForEach(padMapButtons) { btn in
                            mappingTile(btn)
                        }
                    }
                }

                DestructiveTile(
                    id: "controller.reset",
                    icon: "arrow.counterclockwise.circle.fill",
                    title: SakuraL10n.tr("common.reset")
                ) {
                    SakuraBridge.resetButtonMappings()
                    mappingVersion &+= 1
                }
            }

            if let capturingIndex,
               let button = padMapButtons.first(where: { $0.id == capturingIndex }) {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        SFXManager.shared.play(.back)
                        stopCapture()
                    }
                    .overlay {
                        VStack(spacing: 10) {
                            Text(SakuraL10n.trf("controller.mapping.listeningFmt", SakuraL10n.tr(button.nameKey)))
                                .font(.headline.weight(.bold))
                                .foregroundStyle(theme.glassTextPrimary(.dark))
                            Text(SakuraL10n.tr("controller.mapping.instructionTap"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.glassTextPrimary(.dark).opacity(0.9))
                            Text(SakuraL10n.tr("controller.mapping.cancelHint"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange.opacity(0.95))
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(theme.glassTextPrimary(.dark).opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                        )
                        .padding(.horizontal, 28)
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SakuraControllerCaptureCancel"))) { _ in
            if capturingIndex != nil {
                stopCapture()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: sakuraPhysicalMappingCapturedNotifName).receive(on: DispatchQueue.main)) { note in
            guard capturingIndex != nil,
                  let pad = note.userInfo?["padIndex"] as? Int,
                  let sdl = note.userInfo?["sdl"] as? Int else { return }
            guard pad == capturingIndex else { return }
            SakuraBridge.setButtonMapping(Int32(pad), toSDLButton: Int32(sdl))
            stopCapture()
            mappingVersion &+= 1
        }
        .onDisappear {
            stopCapture()
        }
    }

    @ViewBuilder
    private func mappingTile(_ btn: PadMapButton) -> some View {
        let isCapturing = capturingIndex == btn.id
        let currentHost = Int(SakuraBridge.getButtonMapping(Int32(btn.id)))
        let id = Self.mappingID(for: btn.id)
        let isFocused = focus.focusedID == id && focus.region == .content
        let icon = btn.iconName ?? "button.roundedbottom.horizontal"

        Button {
            focus.focusFromTouch(id: id)
            SFXManager.shared.play(.confirm)
            if isCapturing {
                stopCapture()
            } else {
                startCapture(for: btn.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(0.9))
                    Spacer(minLength: 0)
                    if isCapturing {
                        Image(systemName: "record.circle")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }

                Spacer(minLength: 0)

                Text(SakuraL10n.tr(btn.nameKey).uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(isCapturing ? SakuraL10n.tr("pad.pressPrompt") : localizedGamepadButtonName(currentHost))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        isCapturing ? .orange : theme.glassTextPrimary(colorScheme)
                    )
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tileBackground(isCapturing: isCapturing, isFocused: isFocused))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        tileStroke(isCapturing: isCapturing, isFocused: isFocused),
                        lineWidth: (isFocused || isCapturing) ? 2.5 : 1
                    )
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
        .id(id)
        .background(TileColumnReporter(id: id))
        .onChange(of: focus.triggerTick) { _, _ in
            guard focus.triggerID == id && focus.region == .content else { return }
            if isCapturing {
                stopCapture()
            } else {
                startCapture(for: btn.id)
            }
        }
    }

    private func tileBackground(isCapturing: Bool, isFocused: Bool) -> Color {
        if isCapturing { return .orange.opacity(0.22) }
        return theme.glassTileBackground(colorScheme, isFocused: isFocused)
    }

    private func tileStroke(isCapturing: Bool, isFocused: Bool) -> Color {
        if isCapturing { return .orange }
        return theme.glassTileStroke(colorScheme, isFocused: isFocused)
    }

    private func startCapture(for padIndex: Int) {
        capturingIndex = padIndex
        focus.isCapturing = true
        SakuraBridge.startButtonCapture()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { tm in
            SakuraBridge.pollGamepadForCapture()
            let captured = SakuraBridge.capturedButton()
            if captured >= 0 {
                tm.invalidate()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: sakuraPhysicalMappingCapturedNotifName,
                        object: nil,
                        userInfo: ["padIndex": padIndex, "sdl": captured]
                    )
                }
            }
        }
    }

    private func stopCapture() {
        pollTimer?.invalidate()
        pollTimer = nil
        capturingIndex = nil
        focus.isCapturing = false
        SakuraBridge.stopButtonCapture()
    }
}
