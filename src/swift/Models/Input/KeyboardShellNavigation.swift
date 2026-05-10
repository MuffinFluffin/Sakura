// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

// Translates Magic Keyboard / iPad keyboard input into the same `GamepadNavigation`
// paths as physical controllers (`applyKeyboardNavigationAction`), and routes gameplay
// keys through `PadInputRouter` when `GamepadNavigation.context == .emulation`.

struct ShellKeyboardNavigationHost: UIViewRepresentable {
    var shouldClaimFirstResponder: Bool
    var gameplaySuppressed: Bool = false

    func makeUIView(context: Context) -> ShellKeyboardNavigationView {
        let v = ShellKeyboardNavigationView()
        v.hostShouldClaimFirstResponder = shouldClaimFirstResponder
        v.gameplaySuppressed = gameplaySuppressed
        return v
    }

    func updateUIView(_ uiView: ShellKeyboardNavigationView, context: Context) {
        uiView.hostShouldClaimFirstResponder = shouldClaimFirstResponder
        uiView.gameplaySuppressed = gameplaySuppressed
        uiView.applyFirstResponderState()
    }
}

private enum SakuraBracketHID {
    static let left: UInt32 = 0x2F
    static let right: UInt32 = 0x30
}

final class ShellKeyboardNavigationView: UIView {
    var hostShouldClaimFirstResponder = false
    var gameplaySuppressed = false

    override var canBecomeFirstResponder: Bool { hostShouldClaimFirstResponder }

    private struct ShellDirPress {
        var oid: ObjectIdentifier
        var action: GamepadAction
    }

    private var shellDirStack: [ShellDirPress] = []
    private var shellDirHold: GamepadAction?
    private var shellDirInitial: DispatchWorkItem?
    private var shellDirStep: DispatchWorkItem?

    private var shellShoulderLeftPresses: Set<ObjectIdentifier> = []
    private var shellShoulderRightPresses: Set<ObjectIdentifier> = []
    private var shellShoulderLeftInitial: DispatchWorkItem?
    private var shellShoulderLeftStep: DispatchWorkItem?
    private var shellShoulderRightInitial: DispatchWorkItem?
    private var shellShoulderRightStep: DispatchWorkItem?

    private var gameplayPressMap: [ObjectIdentifier: PadButton] = [:]
    private lazy var gameplayCharBindings: [Character: PadButton] = Self.buildGameplayCharBindings()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func applyFirstResponderState() {
        guard window != nil else { return }
        if hostShouldClaimFirstResponder {
            if !isFirstResponder {
                DispatchQueue.main.async { [weak self] in
                    _ = self?.becomeFirstResponder()
                }
            }
        } else {
            if isFirstResponder {
                resignFirstResponder()
            }
            cancelShellDirectionHoldRepeat()
            cancelShellShoulderRepeats()
            releaseAllGameplayPresses()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyFirstResponderState()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            handlePressBegan(press)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            handlePressEnded(press)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            handlePressEnded(press)
        }
    }

    private func handlePressBegan(_ press: UIPress) {
        guard hostShouldClaimFirstResponder else { return }
        guard let key = press.key else { return }
        guard !ignoringKeyForSystemShortcuts(key) else { return }

        if TileFocus.shared.isCapturing {
            if let a = shellActionDuringCapture(for: key) {
                GamepadNavigation.shared.applyKeyboardNavigationAction(a)
            }
            return
        }

        if routesToShellGamepadNav(GamepadNavigation.shared.context) {
            if let a = shellAction(for: key) {
                applyShellAction(a, press: press)
            }
            return
        }

        guard !gameplaySuppressed else { return }
        guard !SakuraBridge.isPhysicalPadToGameSuppressed() else { return }
        guard SakuraBridge.isEmulationRunning(),
              GamepadNavigation.shared.context == .emulation else { return }

        if let btn = gameplayButton(for: key) {
            let id = ObjectIdentifier(press)
            if gameplayPressMap[id] == nil {
                gameplayPressMap[id] = btn
                PadInputRouter.dispatch(btn, pressed: true)
            }
        }
    }

    private func handlePressEnded(_ press: UIPress) {
        let id = ObjectIdentifier(press)
        shellDirectionEnded(press)

        if shellShoulderLeftPresses.remove(id) != nil {
            if shellShoulderLeftPresses.isEmpty {
                cancelShellShoulderLeftRepeat()
            }
        }
        if shellShoulderRightPresses.remove(id) != nil {
            if shellShoulderRightPresses.isEmpty {
                cancelShellShoulderRightRepeat()
            }
        }

        if let btn = gameplayPressMap.removeValue(forKey: id) {
            PadInputRouter.dispatch(btn, pressed: false)
        }
    }

    private func ignoringKeyForSystemShortcuts(_ key: UIKey) -> Bool {
        let m = key.modifierFlags
        if m.contains(.command) || m.contains(.control) { return true }
        if m.contains(.alternate) && !key.charactersIgnoringModifiers.isEmpty { return true }
        return false
    }

    private func routesToShellGamepadNav(_ ctx: GamepadContext) -> Bool {
        switch ctx {
        case .library, .settings, .emulationMenu, .mediaViewer: return true
        case .inactive, .emulation: return false
        }
    }

    private func shellActionDuringCapture(for key: UIKey) -> GamepadAction? {
        switch key.keyCode {
        case .keyboardEscape:
            return .back
        default:
            return nil
        }
    }

    private static func isReturnLike(_ code: UIKeyboardHIDUsage) -> Bool {
        if code == .keyboardReturnOrEnter { return true }
        return code.rawValue == 0x58
    }

    private func shellAction(for key: UIKey) -> GamepadAction? {
        switch key.keyCode {
        case .keyboardLeftArrow: return .moveLeft
        case .keyboardRightArrow: return .moveRight
        case .keyboardUpArrow: return .moveUp
        case .keyboardDownArrow: return .moveDown
        case .keyboardEscape: return .back
        default:
            if Self.isReturnLike(key.keyCode) { return .confirm }
            let raw = key.keyCode.rawValue
            if raw == SakuraBracketHID.left { return .shoulderLeft }
            if raw == SakuraBracketHID.right { return .shoulderRight }
            break
        }

        guard let c = key.charactersIgnoringModifiers.lowercased().first else { return nil }
        switch c {
        case "w": return .moveUp
        case "s": return .moveDown
        case "a": return .moveLeft
        case "d": return .moveRight
        case "\r", "\n": return .confirm
        case "j": return .secondary
        case "l": return .tertiary
        case "m": return .menu
        default:
            return nil
        }
    }

    private func applyShellAction(_ action: GamepadAction, press: UIPress) {
        let id = ObjectIdentifier(press)
        switch action {
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            shellDirectionBegan(action, pressID: id)
        case .shoulderLeft:
            let (inserted, _) = shellShoulderLeftPresses.insert(id)
            if inserted, shellShoulderLeftPresses.count == 1 {
                GamepadNavigation.shared.applyKeyboardNavigationAction(.shoulderLeft)
                scheduleShellShoulderInitial(isLeft: true)
            }
        case .shoulderRight:
            let (inserted, _) = shellShoulderRightPresses.insert(id)
            if inserted, shellShoulderRightPresses.count == 1 {
                GamepadNavigation.shared.applyKeyboardNavigationAction(.shoulderRight)
                scheduleShellShoulderInitial(isLeft: false)
            }
        default:
            GamepadNavigation.shared.applyKeyboardNavigationAction(action)
        }
    }

    private func shellDirectionBegan(_ action: GamepadAction, pressID: ObjectIdentifier) {
        if shellDirStack.contains(where: { $0.oid == pressID }) { return }
        shellDirStack.append(ShellDirPress(oid: pressID, action: action))
        restartShellDirectionRepeatFromTop()
    }

    private func shellDirectionEnded(_ press: UIPress) {
        let id = ObjectIdentifier(press)
        shellDirStack.removeAll { $0.oid == id }
        restartShellDirectionRepeatFromTop()
    }

    private func restartShellDirectionRepeatFromTop() {
        cancelShellDirectionTimersOnly()
        guard let top = shellDirStack.last else {
            shellDirHold = nil
            return
        }
        shellDirHold = top.action
        GamepadNavigation.shared.applyKeyboardNavigationAction(top.action)
        let initial = DispatchWorkItem { [weak self] in
            self?.shellDirectionRepeatStep(top.action)
        }
        shellDirInitial = initial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: initial)
    }

    private func shellDirectionRepeatStep(_ action: GamepadAction) {
        guard shellDirStack.last?.action == action, shellDirHold == action else { return }
        guard routesToShellGamepadNav(GamepadNavigation.shared.context) else {
            cancelShellDirectionHoldRepeat()
            return
        }
        GamepadNavigation.shared.applyKeyboardNavigationAction(action)
        shellDirStep?.cancel()
        let step = DispatchWorkItem { [weak self] in
            self?.shellDirectionRepeatStep(action)
        }
        shellDirStep = step
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: step)
    }

    private func cancelShellDirectionTimersOnly() {
        shellDirInitial?.cancel()
        shellDirStep?.cancel()
        shellDirInitial = nil
        shellDirStep = nil
    }

    private func cancelShellDirectionHoldRepeat() {
        cancelShellDirectionTimersOnly()
        shellDirHold = nil
        shellDirStack.removeAll()
    }

    private func scheduleShellShoulderInitial(isLeft: Bool) {
        if isLeft {
            shellShoulderLeftInitial?.cancel()
            let initial = DispatchWorkItem { [weak self] in
                self?.shellShoulderRepeatStep(isLeft: true)
            }
            shellShoulderLeftInitial = initial
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: initial)
        } else {
            shellShoulderRightInitial?.cancel()
            let initial = DispatchWorkItem { [weak self] in
                self?.shellShoulderRepeatStep(isLeft: false)
            }
            shellShoulderRightInitial = initial
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: initial)
        }
    }

    private func shellShoulderRepeatStep(isLeft: Bool) {
        guard routesToShellGamepadNav(GamepadNavigation.shared.context) else {
            if isLeft { cancelShellShoulderLeftRepeat() } else { cancelShellShoulderRightRepeat() }
            return
        }
        if isLeft {
            guard !shellShoulderLeftPresses.isEmpty else { return }
            GamepadNavigation.shared.applyKeyboardNavigationAction(.shoulderLeft)
            shellShoulderLeftStep?.cancel()
            let step = DispatchWorkItem { [weak self] in
                self?.shellShoulderRepeatStep(isLeft: true)
            }
            shellShoulderLeftStep = step
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: step)
        } else {
            guard !shellShoulderRightPresses.isEmpty else { return }
            GamepadNavigation.shared.applyKeyboardNavigationAction(.shoulderRight)
            shellShoulderRightStep?.cancel()
            let step = DispatchWorkItem { [weak self] in
                self?.shellShoulderRepeatStep(isLeft: false)
            }
            shellShoulderRightStep = step
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: step)
        }
    }

    private func cancelShellShoulderLeftRepeat() {
        shellShoulderLeftInitial?.cancel()
        shellShoulderLeftStep?.cancel()
        shellShoulderLeftInitial = nil
        shellShoulderLeftStep = nil
    }

    private func cancelShellShoulderRightRepeat() {
        shellShoulderRightInitial?.cancel()
        shellShoulderRightStep?.cancel()
        shellShoulderRightInitial = nil
        shellShoulderRightStep = nil
    }

    private func cancelShellShoulderRepeats() {
        cancelShellShoulderLeftRepeat()
        cancelShellShoulderRightRepeat()
        shellShoulderLeftPresses.removeAll()
        shellShoulderRightPresses.removeAll()
    }

    private func gameplayButton(for key: UIKey) -> PadButton? {
        switch key.keyCode {
        case .keyboardLeftArrow: return .left
        case .keyboardRightArrow: return .right
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardTab: return .select
        default:
            if Self.isReturnLike(key.keyCode) { return .start }
            let raw = key.keyCode.rawValue
            if raw == SakuraBracketHID.left { return .L1 }
            if raw == SakuraBracketHID.right { return .R1 }
            break
        }
        let lowered = key.charactersIgnoringModifiers.lowercased()
        guard let ch = lowered.first else { return nil }
        return gameplayCharBindings[ch]
    }

    private func releaseAllGameplayPresses() {
        for (_, btn) in gameplayPressMap {
            PadInputRouter.dispatch(btn, pressed: false)
        }
        gameplayPressMap.removeAll(keepingCapacity: true)
    }

    private static func buildGameplayCharBindings() -> [Character: PadButton] {
        var m: [Character: PadButton] = [:]
        func bind(iniKey: String, defaultChar: Character, button: PadButton) {
            let ch: Character
            if let s = SakuraBridge.keyboardPadBinding(forIniKey: iniKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let f = s.lowercased().first {
                ch = f
            } else {
                ch = defaultChar
            }
            m[ch] = button
        }

        bind(iniKey: "Up", defaultChar: "w", button: .up)
        bind(iniKey: "Down", defaultChar: "s", button: .down)
        bind(iniKey: "Left", defaultChar: "a", button: .left)
        bind(iniKey: "Right", defaultChar: "d", button: .right)
        bind(iniKey: "Cross", defaultChar: "z", button: .cross)
        bind(iniKey: "Circle", defaultChar: "x", button: .circle)
        bind(iniKey: "Square", defaultChar: "c", button: .square)
        bind(iniKey: "Triangle", defaultChar: "v", button: .triangle)
        bind(iniKey: "L1", defaultChar: "[", button: .L1)
        bind(iniKey: "R1", defaultChar: "]", button: .R1)
        bind(iniKey: "L2", defaultChar: "q", button: .L2)
        bind(iniKey: "R2", defaultChar: "e", button: .R2)
        return m
    }
}
