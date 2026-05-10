// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

private let defaultTouchControlSilver = Color(red: 0.79, green: 0.82, blue: 0.87)

// Cheap stand-in for .ultraThinMaterial. Materials do a backdrop Gaussian blur
// every frame which is murder when the Metal game layer behind them is updating
// at 60 Hz × 16 button surfaces. The gradient + stroke overlays each button
// already paints on top of this base produce the glass illusion, so a static
// translucent fill is visually close while costing nothing per frame.
private let touchControlGlassFill = Color.white.opacity(0.06)

private struct VPadDpadCapDiscBackground: View {
    let on: Bool
    let accent: Color
    let padColor: Color
    let strokeColor: Color
    let strokeWidth: CGFloat
    var body: some View {
        let grad = LinearGradient(
            colors: [
                padColor.opacity(on ? 0.24 : 0.18),
                padColor.opacity(0.02),
                .black.opacity(on ? 0.18 : 0.24)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        return Circle()
            .fill(touchControlGlassFill)
            .overlay(Circle().fill(accent.opacity(on ? 0.28 : 0.09)))
            .overlay(Circle().fill(grad))
            .overlay(Circle().stroke(strokeColor.opacity(on ? 0.42 : 0.18), lineWidth: on ? strokeWidth * 1.4 : strokeWidth))
            .overlay(Circle().stroke(accent.opacity(on ? 0.58 : 0.22), lineWidth: on ? strokeWidth * 1.8 : strokeWidth * 1.1))
            .compositingGroup()
            .shadow(color: .black.opacity(on ? 0.22 : 0.34), radius: on ? 4 : 10, y: on ? 2 : 6)
    }
}

private struct VPadFaceDiscBackground: View {
    let on: Bool
    let face: Color
    let padColor: Color
    let strokeColor: Color
    let strokeWidth: CGFloat
    var body: some View {
        let grad = LinearGradient(
            colors: [
                padColor.opacity(on ? 0.24 : 0.18),
                padColor.opacity(0.03),
                .black.opacity(on ? 0.14 : 0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        return Circle()
            .fill(touchControlGlassFill)
            .overlay(Circle().fill(face.opacity(on ? 0.30 : 0.12)))
            .overlay(Circle().fill(grad))
            .overlay(Circle().stroke(strokeColor.opacity(on ? 0.44 : 0.20), lineWidth: on ? strokeWidth * 1.4 : strokeWidth))
            .overlay(
                Circle()
                    .stroke(face.opacity(on ? 0.66 : 0.28), lineWidth: on ? strokeWidth * 1.8 : strokeWidth * 1.1)
            )
            .compositingGroup()
            .shadow(color: .black.opacity(on ? 0.2 : 0.34), radius: on ? 4 : 10, y: on ? 2 : 6)
    }
}

private struct VPadRectButtonBackground: View {
    let on: Bool
    let cornerRadius: CGFloat
    let accent: Color
    let padColor: Color
    let strokeColor: Color
    let strokeWidth: CGFloat
    var body: some View {
        let grad = LinearGradient(
            colors: [
                padColor.opacity(on ? 0.24 : 0.18),
                padColor.opacity(0.03),
                .black.opacity(on ? 0.12 : 0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(touchControlGlassFill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(accent.opacity(on ? 0.3 : 0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(grad)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(strokeColor.opacity(on ? 0.42 : 0.18), lineWidth: on ? strokeWidth * 1.3 : strokeWidth * 0.9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(accent.opacity(on ? 0.62 : 0.24), lineWidth: on ? strokeWidth * 1.8 : strokeWidth * 1.1)
            )
            .compositingGroup()
            .shadow(color: .black.opacity(on ? 0.2 : 0.34), radius: on ? 4 : 10, y: on ? 2 : 6)
    }
}

// MARK: - Pad button geometry + swipe-between-buttons (Fin-parity)
//
// Mirrors DolphiniOS / Fin's TCButton pattern: each touch button reports its
// frame into a shared registry, and each button's drag gesture, on every
// touchesMoved-equivalent, hit-tests the registry for the button currently
// under the finger. If that target differs from what this finger had been
// pressing, the old button is released and the new one pressed in real
// time, without the user lifting. Multi-touch is preserved because each
// finger keeps driving its own originating button's gesture independently.

@Observable
@MainActor
final class PadButtonGeometry {
    static let shared = PadButtonGeometry()

    /// Latest absolute frames for every active touch button, in the
    /// `padContainer` coordinate space declared on the layout root.
    var frames: [PadButton: CGRect] = [:]

    /// Refcounted because two fingers may converge on the same button mid-swipe.
    /// Reads of `pressCount[btn]` drive each button's visual `on` state.
    var pressCount: [PadButton: Int] = [:]

    private init() {}

    func updateFrame(_ btn: PadButton, _ frame: CGRect) {
        if frames[btn] != frame { frames[btn] = frame }
    }

    // smallest-area frame containing the point wins. matches the visual
    // stacking order, e.g. cross sitting under triangle still resolves
    // to triangle when the finger is inside both.
    func buttonAt(_ point: CGPoint) -> PadButton? {
        var best: (btn: PadButton, area: CGFloat)? = nil
        for (btn, frame) in frames where frame.contains(point) {
            let area = frame.width * frame.height
            if best == nil || area < best!.area { best = (btn, area) }
        }
        return best?.btn
    }

    func setPress(_ btn: PadButton, isPressed: Bool, haptic: Bool = true) {
        let c = pressCount[btn] ?? 0
        if isPressed {
            pressCount[btn] = c + 1
            if c == 0 {
                EmulatorBridge.shared.setPadButton(btn, pressed: true)
                if haptic { HapticManager.fireSecondary() }
                // While browsing (library/settings/media on the external display),
                // route virtual L1/R1 taps into the shell-nav action stream so
                // the phone's touchpad can cycle top sections just like a real
                // controller. Without this the user taps L1 on the phone and
                // nothing happens on the TV, the "stuck half-activated" feel.
                if AppState.shared.currentScreen != .playing {
                    switch btn {
                    case .L1: GamepadNavigation.shared.injectShellAction(.shoulderLeft)
                    case .R1: GamepadNavigation.shared.injectShellAction(.shoulderRight)
                    default: break
                    }
                }
            }
        } else {
            guard c > 0 else { return }
            pressCount[btn] = c - 1
            if c == 1 {
                EmulatorBridge.shared.setPadButton(btn, pressed: false)
            }
        }
    }

    func isHeld(_ btn: PadButton) -> Bool {
        (pressCount[btn] ?? 0) > 0
    }

    /// Drop all touch-held buttons and clear refcounts so transitions (e.g. AirPlay / screen) never leave the core stuck.
    func releaseAll() {
        for (btn, count) in pressCount where count > 0 {
            EmulatorBridge.shared.setPadButton(btn, pressed: false)
        }
        pressCount.removeAll(keepingCapacity: false)
    }
}

struct PadButtonSwipeModifier: ViewModifier {
    let selfBtn: PadButton
    @State private var heldByThisFinger: PadButton? = nil

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            PadButtonGeometry.shared.updateFrame(
                                selfBtn,
                                proxy.frame(in: .named("padContainer"))
                            )
                        }
                        .onChange(of: proxy.frame(in: .named("padContainer"))) { _, new in
                            PadButtonGeometry.shared.updateFrame(selfBtn, new)
                        }
                }
            )
            // `.simultaneousGesture` (not `.gesture`) so the per-button drag
            // coexists with any ancestor gesture recognizer stacked on the
            // SakuraPhoneTouchPadShell / floating-top-button overlay. Using
            // `.gesture` here let the overlay's tap-recognizer claim the
            // touch stream first, which is why buttons were "visible but
            // unresponsive" during gameplay.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("padContainer"))
                    .onChanged { v in
                        let target = PadButtonGeometry.shared.buttonAt(v.location)
                        if target != heldByThisFinger {
                            if let old = heldByThisFinger {
                                PadButtonGeometry.shared.setPress(old, isPressed: false)
                            }
                            if let new = target {
                                PadButtonGeometry.shared.setPress(new, isPressed: true)
                            }
                            heldByThisFinger = target
                        }
                    }
                    .onEnded { _ in
                        if let held = heldByThisFinger {
                            PadButtonGeometry.shared.setPress(held, isPressed: false)
                        }
                        heldByThisFinger = nil
                    }
            )
    }
}

extension View {
    /// Apply to any touch button to enable Fin-style press + swipe-between-buttons.
    func padButtonSwipe(_ btn: PadButton) -> some View {
        modifier(PadButtonSwipeModifier(selfBtn: btn))
    }
}

private func sakuraDpadDirections(at point: CGPoint, size: CGFloat) -> Set<PadButton> {
    let cx = point.x - size * 0.5
    let cy = point.y - size * 0.5
    let r = hypot(cx, cy)
    let dead = size * 0.13
    guard r >= dead else { return [] }

    var a = atan2(cx, -cy)
    if a < 0 { a += CGFloat.pi * 2 }
    let eighth = CGFloat.pi / 4
    let idx = Int((a + eighth * 0.5) / eighth) % 8
    switch idx {
    case 0: return [.up]
    case 1: return [.up, .right]
    case 2: return [.right]
    case 3: return [.down, .right]
    case 4: return [.down]
    case 5: return [.down, .left]
    case 6: return [.left]
    case 7: return [.up, .left]
    default: return []
    }
}

private struct DPadUnifiedTouchModifier: ViewModifier {
    let size: CGFloat
    @State private var held: Set<PadButton> = []

    func body(content: Content) -> some View {
        content.overlay(alignment: .center) {
            Color.clear
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in
                            let next = sakuraDpadDirections(at: v.location, size: size)
                            let wasEmpty = held.isEmpty
                            for b in held.subtracting(next) {
                                PadButtonGeometry.shared.setPress(b, isPressed: false, haptic: false)
                            }
                            for b in next.subtracting(held) {
                                PadButtonGeometry.shared.setPress(b, isPressed: true, haptic: false)
                            }
                            held = next
                            if wasEmpty, !next.isEmpty { HapticManager.fireSecondary() }
                        }
                        .onEnded { _ in
                            for b in held {
                                PadButtonGeometry.shared.setPress(b, isPressed: false, haptic: false)
                            }
                            held = []
                        }
                )
        }
    }
}

struct PadChromeLayoutMetrics: Sendable {
    var minX: CGFloat
    var minY: CGFloat
    var width: CGFloat
    var height: CGFloat

    static func emulation(size: CGSize, safeInsets: EdgeInsets) -> PadChromeLayoutMetrics {
        let left = safeInsets.leading
        let top = safeInsets.top
        let trailing = safeInsets.trailing
        let bottom = safeInsets.bottom
        let lw = max(72, size.width - left - trailing)
        let lh = max(72, size.height - top - bottom)
        return PadChromeLayoutMetrics(minX: left, minY: top, width: lw, height: lh)
    }
}

/// Same phone layout as `EmulationView` game/video stack: full-screen black, sized center layer, virtual pad on top.
struct SakuraPhoneTouchPadShell<Center: View>: View {
    @Binding var isEditMode: Bool
    @Binding var selectedGroupID: String
    var padVisible: Bool
    @ViewBuilder var center: (_ sw: CGFloat, _ sh: CGFloat) -> Center

    @ObservedObject private var secondaryDisplay = SecondaryDisplayCoordinator.shared
    @State private var appState = AppState.shared

    var body: some View {
        GeometryReader { geo in
            let sw = geo.size.width
            let sh = geo.size.height
            ZStack {
                Color.black
                    .frame(width: sw, height: sh)
                center(sw, sh)
                    .frame(width: sw, height: sh)
                if padVisible {
                    VirtualControllerView(
                        isEditMode: $isEditMode,
                        selectedGroupID: $selectedGroupID
                    )
                    .frame(width: sw, height: sh)
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .onChange(of: secondaryDisplay.externalRasterSurfaceAvailable) { _, _ in
            PadButtonGeometry.shared.releaseAll()
        }
        .onChange(of: secondaryDisplay.externalBrowsingSuspended) { _, _ in
            // Toggling "Stop TV" / "Resume on TV" remounts the shell; drop any
            // in-flight touch refcounts so a finger lifted mid-transition
            // doesn't leave a button half-activated.
            PadButtonGeometry.shared.releaseAll()
        }
        .onChange(of: appState.currentScreen) { _, _ in
            PadButtonGeometry.shared.releaseAll()
        }
        .onChange(of: appState.runningGameName) { _, _ in
            // Game start/stop can swallow the trailing touch-up delivered by
            // SwiftUI on a remounted gesture recognizer.
            PadButtonGeometry.shared.releaseAll()
        }
    }
}

struct VirtualControllerView: View {
    @Bindable private var settings = SettingsStore.shared
    @State private var layout = PadLayoutStore.shared
    @State private var theme = ThemeManager.shared
    @Binding var isEditMode: Bool
    @Binding var selectedGroupID: String

    // bumped whenever PS1 controller mode flips between digital and DualShock so the
    // body re-evaluates `isDigitalMode` and the analog stick widgets disappear
    // / reappear immediately. The bridge stores mode in INI, which SwiftUI
    // can't observe directly. notifications carry the change instead.
    @State private var ps1ModeRevision: Int = 0

    init(isEditMode: Binding<Bool> = .constant(false),
         selectedGroupID: Binding<String> = .constant("dpad")) {
        self._isEditMode = isEditMode
        self._selectedGroupID = selectedGroupID
    }

    private var isDigitalMode: Bool {
        _ = ps1ModeRevision
        return Int(SakuraBridge.ps1CoreControllerMode(forPort: 0)) == 0
    }

    var body: some View {
        GeometryReader { geo in
            let metrics = PadChromeLayoutMetrics.emulation(size: geo.size, safeInsets: geo.safeAreaInsets)
            padChromeLayout(metrics: metrics)
                .opacity(isEditMode ? 1 : Double(settings.padOpacity))
        }
        .onAppear {
            // Any touch refcounts sitting at > 0 when the pad first mounts are
            // leftovers from a previous session whose gesture never got a
            // matching touch-up (app backgrounded mid-press, view torn down by
            // AirPlay transition, etc.). Without this, the user sees buttons
            // rendered in their "held" state forever, the "frozen buttons"
            // complaint.
            PadButtonGeometry.shared.releaseAll()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("SakuraPS1ControllerModeChanged"))
        ) { _ in
            ps1ModeRevision &+= 1
        }
    }

    private var padLayoutModeForChrome: Int {
        isDigitalMode ? 0 : 1
    }

    private var visibleGroupIDs: [String] {
        PadLayoutStore.layoutGroupIDs(forPS1Mode: padLayoutModeForChrome)
    }

    private func pos(_ id: String) -> PadGroupPosition {
        layout.position(for: id)
    }

    private func tint(_ id: String) -> Color? {
        let key = layout.colorKey(for: id)
        guard !key.isEmpty else { return nil }
        return theme.color(forKey: key)
    }

    private func strokeTint(_ id: String) -> Color? {
        let key = layout.strokeColorKey(for: id)
        guard !key.isEmpty else { return nil }
        return theme.color(forKey: key)
    }

    @ViewBuilder
    func padChromeLayout(metrics: PadChromeLayoutMetrics) -> some View {
        ZStack {
            ForEach(visibleGroupIDs, id: \.self) { id in
                editableGroup(id: id, metrics: metrics)
            }
        }
        .coordinateSpace(name: "padContainer")
    }

    @ViewBuilder
    private func editableGroup(id: String, metrics: PadChromeLayoutMetrics) -> some View {
        let p = pos(id)
        if isEditMode {
            EditableGroupWrapper(
                id: id,
                metrics: metrics,
                isSelected: selectedGroupID == id,
                onSelect: { selectedGroupID = id }
            ) {
                groupContent(id: id)
            }
        } else {
            groupContent(id: id)
                .scaleEffect(p.scale * layout.globalScale)
                .position(x: metrics.minX + p.x * metrics.width, y: metrics.minY + p.y * metrics.height)
        }
    }

    @ViewBuilder
    private func groupContent(id: String) -> some View {
        switch id {
        case "dpad":         DPadView(size: 118, tint: tint("dpad"), strokeTint: strokeTint("dpad"))
        case "btn_triangle": PSBtn(sym: "△", clr: tint("btn_triangle") ?? .green, strokeClr: strokeTint("btn_triangle"), sz: 62, btn: .triangle)
        case "btn_circle":   PSBtn(sym: "○", clr: tint("btn_circle")   ?? .red,   strokeClr: strokeTint("btn_circle"), sz: 68, btn: .circle)
        case "btn_cross":    PSBtn(sym: "✕", clr: tint("btn_cross")    ?? .blue,  strokeClr: strokeTint("btn_cross"), sz: 72, btn: .cross)
        case "btn_square":   PSBtn(sym: "□", clr: tint("btn_square")   ?? .pink,  strokeClr: strokeTint("btn_square"), sz: 62, btn: .square)
        case "l2":           PadBtn(label: "L2", w: 92, h: 46, btn: .L2, tint: tint("l2"), strokeTint: strokeTint("l2"))
        case "l1":           PadBtn(label: "L1", w: 92, h: 46, btn: .L1, tint: tint("l1"), strokeTint: strokeTint("l1"))
        case "r2":           PadBtn(label: "R2", w: 92, h: 46, btn: .R2, tint: tint("r2"), strokeTint: strokeTint("r2"))
        case "r1":           PadBtn(label: "R1", w: 92, h: 46, btn: .R1, tint: tint("r1"), strokeTint: strokeTint("r1"))
        case "select":       PadBtn(label: PadLayoutStore.localizedGroupLabel(for: "select").uppercased(), w: 66, h: 30, btn: .select, tint: tint("select"), strokeTint: strokeTint("select"))
        case "start":        PadBtn(label: PadLayoutStore.localizedGroupLabel(for: "start").uppercased(), w: 66, h: 30, btn: .start, tint: tint("start"), strokeTint: strokeTint("start"))
        case "lstick":       StickView(isLeft: true, tint: tint("lstick"), strokeTint: strokeTint("lstick"))
        case "rstick":       StickView(isLeft: false, tint: tint("rstick"), strokeTint: strokeTint("rstick"))
        default:             EmptyView()
        }
    }
}


private struct EditableGroupWrapper<Content: View>: View {
    let id: String
    let metrics: PadChromeLayoutMetrics
    let isSelected: Bool
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var layout = PadLayoutStore.shared
    @State private var theme = ThemeManager.shared
    @State private var dragOffset: CGSize = .zero
    @State private var currentPinchScale: CGFloat = 1.0

    private var pos: PadGroupPosition {
        layout.position(for: id)
    }

    private var accentColor: Color {
        let key = layout.colorKey(for: id)
        if !key.isEmpty, let c = Optional(theme.color(forKey: key)) { return c }
        return defaultTouchControlSilver
    }

    private var baseHitSize: CGSize {
        switch id {
        case "dpad": return CGSize(width: 118, height: 118)
        case "btn_triangle": return CGSize(width: 62, height: 62)
        case "btn_circle": return CGSize(width: 68, height: 68)
        case "btn_square": return CGSize(width: 62, height: 62)
        case "btn_cross": return CGSize(width: 72, height: 72)
        case "l1", "l2", "r1", "r2": return CGSize(width: 92, height: 46)
        case "select", "start": return CGSize(width: 66, height: 30)
        case "lstick", "rstick": return CGSize(width: 144, height: 96)
        default: return CGSize(width: 72, height: 72)
        }
    }

    private var hitSize: CGSize {
        let scale = pos.scale * layout.globalScale * currentPinchScale
        return CGSize(
            width: max(52, baseHitSize.width * scale),
            height: max(52, baseHitSize.height * scale)
        )
    }

    var body: some View {
        let drag = DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if !isSelected { onSelect() }
                dragOffset = v.translation
            }
            .onEnded { v in
                let lw = metrics.width
                let lh = metrics.height
                let nx = metrics.minX + pos.x * lw + v.translation.width
                let ny = metrics.minY + pos.y * lh + v.translation.height
                let newX = max(0.05, min(0.95, (nx - metrics.minX) / lw))
                let newY = max(0.05, min(0.95, (ny - metrics.minY) / lh))
                var p = pos
                p.x = newX
                p.y = newY
                layout.positions[id] = p
                layout.save()
                dragOffset = .zero
            }

        ZStack {
            content()
                .scaleEffect(pos.scale * layout.globalScale * currentPinchScale)
                .allowsHitTesting(false)
        }
        .frame(width: hitSize.width, height: hitSize.height)
        .contentShape(Rectangle())
        .position(
            x: metrics.minX + pos.x * metrics.width + dragOffset.width,
            y: metrics.minY + pos.y * metrics.height + dragOffset.height
        )
        .highPriorityGesture(drag)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { v in currentPinchScale = v.magnification }
                .onEnded { v in
                    let newScale = max(0.5, min(1.8, pos.scale * v.magnification))
                    var p = pos
                    p.scale = newScale
                    layout.positions[id] = p
                    layout.save()
                    currentPinchScale = 1.0
                }
        )
    }
}

struct DPadView: View {
    let size: CGFloat
    var tint: Color? = nil
    var strokeTint: Color? = nil
    var body: some View {
        let capSize = size * 0.42
        let offset = size * 0.31
        let centerSize = size * 0.22
        ZStack {
            Circle()
                .fill(touchControlGlassFill)
                .overlay(Circle().fill((tint ?? defaultTouchControlSilver).opacity(0.1)))
                .overlay(Circle().stroke((strokeTint ?? .white).opacity(0.16), lineWidth: 0.8))
                .frame(width: centerSize, height: centerSize)

            DPadCap(label: "↑", size: capSize, btn: .up, tint: tint, strokeTint: strokeTint).offset(y: -offset)
            DPadCap(label: "↓", size: capSize, btn: .down, tint: tint, strokeTint: strokeTint).offset(y: offset)
            DPadCap(label: "←", size: capSize, btn: .left, tint: tint, strokeTint: strokeTint).offset(x: -offset)
            DPadCap(label: "→", size: capSize, btn: .right, tint: tint, strokeTint: strokeTint).offset(x: offset)
        }
        .frame(width: size, height: size)
        .modifier(DPadUnifiedTouchModifier(size: size))
    }
}

private struct DPadCap: View {
    let label: String
    let size: CGFloat
    let btn: PadButton
    var tint: Color? = nil
    var strokeTint: Color? = nil

    // plain let on @Observable singletons. SwiftUI tracks property reads
    // inside `body` via @Observable's registrar. Wrapping these in @State
    // pins the reference but breaks per-property observation, which is why
    // button "on" visuals were desyncing from actual press state.
    private let theme = ThemeManager.shared
    private let geom = PadButtonGeometry.shared

    private var accent: Color { tint ?? defaultTouchControlSilver }
    private var padColor: Color { theme.color(forKey: theme.vpadColorKey) }
    private var strokeColor: Color { strokeTint ?? theme.color(forKey: theme.vpadStrokeColorKey) }

    var body: some View {
        let on = geom.isHeld(btn)
        Text(label)
            .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
            .foregroundStyle(theme.topBarTextColor().opacity(on ? 1.0 : 0.88))
            .frame(width: size, height: size)
            .background {
                VPadDpadCapDiscBackground(on: on, accent: accent, padColor: padColor, strokeColor: strokeColor, strokeWidth: theme.vpadStrokeWidth)
            }
            .scaleEffect(on ? 0.93 : 1.0)
            .animation(.easeOut(duration: 0.06), value: on)
            .contentShape(Circle())
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(sakuraA11yPadName(btn))
            .accessibilityHint(SakuraL10n.tr("accessibility.vpad.pressHint"))
    }
}

struct PSBtn: View {
    let sym: String; let clr: Color; let strokeClr: Color?; let sz: CGFloat; let btn: PadButton
    private let theme = ThemeManager.shared
    private let geom = PadButtonGeometry.shared

    private var padColor: Color { theme.color(forKey: theme.vpadColorKey) }
    private var strokeColor: Color { strokeClr ?? theme.color(forKey: theme.vpadStrokeColorKey) }

    var body: some View {
        let on = geom.isHeld(btn)
        Text(sym)
            .font(.system(size: sz * 0.52, weight: .bold, design: .rounded))
            .foregroundStyle(theme.topBarTextColor().opacity(on ? 1.0 : 0.9))
            .frame(width: sz, height: sz)
            .background {
                VPadFaceDiscBackground(on: on, face: clr, padColor: padColor, strokeColor: strokeColor, strokeWidth: theme.vpadStrokeWidth)
            }
            .scaleEffect(on ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.06), value: on)
            .contentShape(Circle())
            .padButtonSwipe(btn)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(sakuraA11yPadName(btn))
            .accessibilityHint(SakuraL10n.tr("accessibility.vpad.pressHint"))
    }
}

struct PadBtn: View {
    let label: String; let w: CGFloat; let h: CGFloat; let btn: PadButton
    var tint: Color? = nil
    var strokeTint: Color? = nil
    private let theme = ThemeManager.shared
    private let geom = PadButtonGeometry.shared
    private var accent: Color { tint ?? defaultTouchControlSilver }
    private var padColor: Color { theme.color(forKey: theme.vpadColorKey) }
    private var strokeColor: Color { strokeTint ?? theme.color(forKey: theme.vpadStrokeColorKey) }
    private var cornerRadius: CGFloat {
        if w >= h * 2.2 { return h * 0.5 }
        return min(h * 0.42, 16)
    }

    var body: some View {
        let on = geom.isHeld(btn)
        Text(label)
            .font(.system(size: min(w, h) * (w > h * 2.2 ? 0.42 : 0.46), weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.35)
            .tracking(0)
            .foregroundStyle(theme.topBarTextColor().opacity(on ? 1.0 : 0.92))
            .frame(width: w, height: h)
            .background {
                VPadRectButtonBackground(on: on, cornerRadius: cornerRadius, accent: accent, padColor: padColor, strokeColor: strokeColor, strokeWidth: theme.vpadStrokeWidth)
            }
            .scaleEffect(on ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.06), value: on)
            .contentShape(Rectangle())
            .padButtonSwipe(btn)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(sakuraA11yPadName(btn))
            .accessibilityHint(SakuraL10n.tr("accessibility.vpad.pressHint"))
    }
}

struct StickView: View {
    let isLeft: Bool
    var tint: Color? = nil
    var strokeTint: Color? = nil
    let sz: CGFloat = 96
    @State private var theme = ThemeManager.shared
    private var knobIdle: CGFloat { sz * 0.35 }
    private let handleMinScale: CGFloat = 0.28
    private let effectiveRadiusScale: CGFloat = 1.4

    @State private var off: CGSize = .zero
    @State private var isDragging = false
    @State private var handleScale: CGFloat = 1.0

    var body: some View {
        let accent = tint ?? defaultTouchControlSilver
        let maxR = sz / 2.0
        let padColor = theme.color(forKey: theme.vpadColorKey)
        let strokeColor = strokeTint ?? theme.color(forKey: theme.vpadStrokeColorKey)
        let strokeWidth = theme.vpadStrokeWidth
        ZStack(alignment: .center) {
            Color.clear.frame(width: sz, height: sz)
            Circle()
                .fill(touchControlGlassFill)
                .overlay(Circle().fill(accent.opacity(isDragging ? 0.18 : 0.08)))
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    padColor.opacity(0.2),
                                    padColor.opacity(0.02),
                                    .black.opacity(0.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(Circle().stroke(strokeColor.opacity(0.18), lineWidth: strokeWidth * 0.9))
                .overlay(Circle().stroke(accent.opacity(isDragging ? 0.45 : 0.18), lineWidth: isDragging ? strokeWidth * 1.8 : strokeWidth * 1.0))
                .frame(width: sz, height: sz)
                .compositingGroup()
                .shadow(color: .black.opacity(0.34), radius: 12, y: 8)

            Circle()
                .fill(touchControlGlassFill)
                .overlay(Circle().fill(accent.opacity(isDragging ? 0.34 : 0.18)))
                .overlay(Circle().stroke(strokeColor.opacity(0.28), lineWidth: strokeWidth * 0.9))
                .frame(width: knobIdle, height: knobIdle)
                .scaleEffect(handleScale)
                .compositingGroup()
                .shadow(color: .black.opacity(0.26), radius: 6, y: 4)
                .offset(off)
        }
        .frame(width: sz, height: sz)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                let dist = hypot(v.translation.width, v.translation.height)
                if dist > 4 {
                    isDragging = true
                    let clampedDist = min(dist, maxR)
                    let angle = atan2(v.translation.height, v.translation.width)
                    off = CGSize(width: cos(angle) * clampedDist, height: sin(angle) * clampedDist)

                    let normMag = min(1.0, dist / maxR)
                    handleScale = 1.0 - (1.0 - handleMinScale) * normMag

                    let effectiveMax = maxR * effectiveRadiusScale
                    let nx = Float(max(-1, min(1, v.translation.width / effectiveMax)))
                    let ny = Float(max(-1, min(1, v.translation.height / effectiveMax)))
                    isLeft ? EmulatorBridge.shared.setLeftStick(x: nx, y: ny)
                           : EmulatorBridge.shared.setRightStick(x: nx, y: ny)
                }
            }
            .onEnded { _ in
                if isDragging {
                    withAnimation(theme.stickSnapBackAnimation) {
                        off = .zero
                        handleScale = 1.0
                    }
                    isLeft ? EmulatorBridge.shared.setLeftStick(x: 0, y: 0)
                           : EmulatorBridge.shared.setRightStick(x: 0, y: 0)
                }
                isDragging = false
            })
            .accessibilityAddTraits([.isButton, .allowsDirectInteraction])
            .accessibilityLabel(SakuraL10n.tr(isLeft ? "pad.group.leftStick" : "pad.group.rightStick"))
            .accessibilityHint(SakuraL10n.tr("accessibility.vpad.stickHint"))
    }
}
