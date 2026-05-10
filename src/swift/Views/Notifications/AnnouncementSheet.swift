// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

struct NotificationLinkAction: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let url: URL
    let icon: String?
    let tintKey: String?
}

struct AnnouncementFullscreenView: View {
    let announcement: Announcement
    let onDismiss: () -> Void

    @State private var theme = ThemeManager.shared

    private var tintColor: Color {
        if let key = announcement.tintKey {
            return theme.color(forKey: key)
        }
        return theme.accentColor()
    }

    private var resolvedActions: [NotificationLinkAction] {
        // declared links + any [label](url) found inside the body, deduped by URL.
        var seenURLs = Set<String>()
        var out: [NotificationLinkAction] = []
        for link in announcement.actionLinks {
            guard let u = link.parsedURL else { continue }
            let key = u.absoluteString
            if seenURLs.contains(key) { continue }
            seenURLs.insert(key)
            out.append(NotificationLinkAction(label: link.label, url: u, icon: link.icon, tintKey: link.tintKey))
        }
        if let body = announcement.body {
            for inline in InlineLinkParser.extract(from: body) {
                let key = inline.url.absoluteString
                if seenURLs.contains(key) { continue }
                seenURLs.insert(key)
                out.append(NotificationLinkAction(label: inline.label, url: inline.url, icon: nil, tintKey: nil))
            }
        }
        return out
    }

    var body: some View {
        NotificationFullscreenView(
            title: announcement.title,
            message: announcement.body,
            icon: announcement.icon ?? "megaphone.fill",
            tintColor: tintColor,
            actions: resolvedActions,
            onDismiss: onDismiss
        )
    }
}

struct CardNotificationFullscreenView: View {
    let card: SakuraNotificationCenter.Card
    let onDismiss: () -> Void

    @State private var theme = ThemeManager.shared

    private var tintColor: Color {
        if let key = card.tintKey {
            return theme.color(forKey: key)
        }
        switch card.kind {
        case .controller: return theme.controllerNotificationTint()
        default: return theme.notificationTint()
        }
    }

    private var actionsFromInlineLinks: [NotificationLinkAction] {
        guard let body = card.subtitle else { return [] }
        return InlineLinkParser.extract(from: body).map {
            NotificationLinkAction(label: $0.label, url: $0.url, icon: nil, tintKey: nil)
        }
    }

    var body: some View {
        NotificationFullscreenView(
            title: card.title,
            message: card.subtitle,
            icon: card.icon,
            tintColor: tintColor,
            actions: actionsFromInlineLinks,
            onDismiss: onDismiss
        )
    }
}

struct NotificationFullscreenView: View {
    let title: String
    let message: String?
    let icon: String
    let tintColor: Color
    let actions: [NotificationLinkAction]
    let onDismiss: () -> Void

    @State private var theme = ThemeManager.shared
    @State private var gamepad = GamepadNavigation.shared
    @State private var focusIndex: Int = 0
    @State private var lastObservedActionID: Int = -1

    /// Total focusable rows: every link + the dismiss row.
    private var rowCount: Int { actions.count + 1 }

    private var dismissIndex: Int { actions.count }

    /// SwiftUI markdown rendering needs a non-empty string. Returns nil when
    /// the body is empty. Markdown links keep their tap targets even though
    /// controller focus is driven by the explicit row buttons below.
    private var attributedBody: AttributedString? {
        guard let raw = message, !raw.isEmpty else { return nil }
        if let attr = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attr
        }
        return AttributedString(raw)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            GeometryReader { geometry in
                VStack(spacing: 14) {
                    ScrollView {
                        VStack(spacing: 22) {
                            Image(systemName: icon)
                                .font(.system(size: 48, weight: .medium))
                                .foregroundStyle(tintColor)
                                .padding(.bottom, 4)

                            Text(title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(theme.glassTextPrimary(.dark))
                                .multilineTextAlignment(.center)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)

                            if let attributedBody {
                                Text(attributedBody)
                                    .font(.body)
                                    .foregroundStyle(theme.glassTextSecondary(.dark))
                                    .tint(tintColor)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if !actions.isEmpty {
                                VStack(spacing: 10) {
                                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                        actionRow(
                                            label: action.label,
                                            icon: action.icon ?? "arrow.up.right.square",
                                            tint: tintColorForAction(action),
                                            isFocused: focusIndex == index
                                        ) {
                                            openAction(action)
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: min(680, max(0, geometry.size.width - 48)))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, max(44, geometry.safeAreaInsets.top + 24))
                        .padding(.bottom, 12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    dismissButton(isFocused: focusIndex == dismissIndex)
                        .padding(.horizontal, 24)

                    controllerHintFooter
                        .padding(.horizontal, 24)
                        .padding(.bottom, max(20, geometry.safeAreaInsets.bottom + 6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            focusIndex = actions.isEmpty ? dismissIndex : 0
            lastObservedActionID = gamepad.actionID
        }
        .onChange(of: gamepad.actionID) { _, _ in
            handleGamepadAction()
        }
    }

    @ViewBuilder
    private func actionRow(label: String, icon: String, tint: Color, isFocused: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22)
                Text(label)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 480)
            .background(
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .fill(tint.opacity(isFocused ? 0.28 : 0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .stroke(tint.opacity(isFocused ? 0.95 : 0.4), lineWidth: isFocused ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    @ViewBuilder
    private func dismissButton(isFocused: Bool) -> some View {
        Button {
            onDismiss()
        } label: {
            Text(SakuraL10n.tr("common.dismiss"))
                .font(.headline.weight(.semibold))
                .foregroundStyle(theme.glassTextPrimary(.dark))
                .frame(maxWidth: 240)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                        .fill(theme.glassTextPrimary(.dark).opacity(isFocused ? 0.22 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                        .stroke(theme.glassTextPrimary(.dark).opacity(isFocused ? 0.85 : 0.2), lineWidth: isFocused ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    @ViewBuilder
    private var controllerHintFooter: some View {
        let showHints = gamepad.shellNavInputActive
        if showHints {
            HStack(spacing: 18) {
                hintGlyph(symbol: "arrow.up.arrow.down.circle.fill", caption: SakuraL10n.tr("common.move"))
                hintGlyph(symbol: gamepad.isPlayStation ? "x.circle.fill" : "a.circle.fill", caption: SakuraL10n.tr("common.select"))
                hintGlyph(symbol: gamepad.isPlayStation ? "circle.circle.fill" : "b.circle.fill", caption: SakuraL10n.tr("common.dismiss"))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.glassTextSecondary(.dark).opacity(0.85))
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func hintGlyph(symbol: String, caption: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            Text(caption)
        }
    }

    private func tintColorForAction(_ action: NotificationLinkAction) -> Color {
        if let key = action.tintKey {
            return theme.color(forKey: key)
        }
        return tintColor
    }

    private func openAction(_ action: NotificationLinkAction) {
        SFXManager.shared.play(.confirm)
        UIApplication.shared.open(action.url, options: [:], completionHandler: nil)
        onDismiss()
    }

    private func handleGamepadAction() {
        guard let last = gamepad.lastAction else { return }
        guard gamepad.actionID != lastObservedActionID else { return }
        lastObservedActionID = gamepad.actionID

        switch last {
        case .moveUp:
            moveFocus(-1)
        case .moveDown:
            moveFocus(1)
        case .moveLeft, .moveRight:
            // keep behaviour predictable on a single column. left/right do nothing.
            break
        case .confirm:
            triggerFocused()
        case .back, .secondary:
            SFXManager.shared.play(.back)
            onDismiss()
        default:
            break
        }
    }

    private func moveFocus(_ delta: Int) {
        guard rowCount > 1 else { return }
        let next = (focusIndex + delta + rowCount) % rowCount
        if next != focusIndex {
            focusIndex = next
            SFXManager.shared.play(.navigate)
        }
    }

    private func triggerFocused() {
        if focusIndex == dismissIndex {
            SFXManager.shared.play(.confirm)
            onDismiss()
            return
        }
        guard actions.indices.contains(focusIndex) else {
            onDismiss()
            return
        }
        openAction(actions[focusIndex])
    }
}

/// Pulls `[label](url)` markdown link patterns out of a string.
enum InlineLinkParser {
    struct Hit: Equatable {
        let label: String
        let url: URL
    }

    private static let pattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#, options: [])
    }()

    static func extract(from raw: String) -> [Hit] {
        guard let regex = pattern else { return [] }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))
        var out: [Hit] = []
        for m in matches where m.numberOfRanges >= 3 {
            let label = ns.substring(with: m.range(at: 1))
            let urlString = ns.substring(with: m.range(at: 2))
            guard let u = URL(string: urlString), u.scheme != nil else { continue }
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanLabel.isEmpty else { continue }
            out.append(Hit(label: cleanLabel, url: u))
        }
        return out
    }
}
