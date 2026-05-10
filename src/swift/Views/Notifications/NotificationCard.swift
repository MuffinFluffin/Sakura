// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct NotificationCard: View {
    let card: SakuraNotificationCenter.Card
    let maxWidth: CGFloat
    let onDismiss: () -> Void
    let onOpen: () -> Void

    @State private var theme = ThemeManager.shared
    @State private var dragOffset: CGSize = .zero
    @GestureState private var trackingFinger = false

    private var tintColor: Color {
        if let key = card.tintKey {
            return theme.color(forKey: key)
        }
        switch card.kind {
        case .controller: return theme.controllerNotificationTint()
        default: return theme.notificationTint()
        }
    }

    private var borderWidth: CGFloat {
        theme.highContrastOutlines ? 2 : (theme.increaseContrast ? 1.5 : 1)
    }

    private var borderOpacity: Double {
        theme.highContrastOutlines ? 0.8 : (theme.increaseContrast ? 0.65 : 0.45)
    }

    private func dynamicTypeSize(for scale: Double) -> DynamicTypeSize {
        if scale < 0.9 { return .small }
        if scale < 1.0 { return .medium }
        if scale < 1.1 { return .large }
        if scale < 1.2 { return .xLarge }
        if scale < 1.3 { return .xxLarge }
        return .xxxLarge
    }

    private var borderStrokeColor: Color {
        if trackingFinger {
            return theme.color(forKey: "red").opacity(theme.highContrastOutlines ? 0.95 : 0.78)
        }
        return tintColor.opacity(borderOpacity)
    }

    private var cardBgOpacity: Double {
        theme.materialsReduced ? 0.9 : (theme.reduceTransparency ? 0.95 : 0.78)
    }

    private var highlightOverlayOpacity: Double {
        trackingFinger ? (theme.materialsReduced ? 0.42 : (theme.reduceTransparency ? 0.42 : 0.28)) : 0
    }

    private var cardDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($trackingFinger) { _, state, _ in
                state = true
            }
            .onChanged { value in
                dragOffset = CGSize(width: value.translation.width, height: 0)
            }
            .onEnded { value in
                let horizontalMovement = abs(value.translation.width)
                let verticalMovement = abs(value.translation.height)

                if horizontalMovement > 80 {
                    let direction: CGFloat = value.translation.width > 0 ? 1 : -1
                    if theme.animationsReduced {
                        onDismiss()
                    } else {
                        withAnimation(theme.notificationDismissThrowAnimation) {
                            dragOffset = CGSize(width: 500 * direction, height: 0)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onDismiss()
                        }
                    }
                } else if horizontalMovement <= 8, verticalMovement <= 8 {
                    dragOffset = .zero
                    onOpen()
                } else {
                    withAnimation(theme.notificationGestureSnapAnimation) {
                        dragOffset = .zero
                    }
                }
            }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(tintColor.opacity(0.2))
                Image(systemName: card.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tintColor)
            }
            .frame(width: 28, height: 28)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.glassTextPrimary(.dark))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = card.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.glassTextSecondary(.dark))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: maxWidth, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
            Group {
                if theme.materialsReduced {
                    shape.fill(Color.black.opacity(cardBgOpacity))
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay(
                            shape.fill(Color.black.opacity(cardBgOpacity * 0.8))
                        )
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                .fill(theme.color(forKey: "red").opacity(highlightOverlayOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                .strokeBorder(borderStrokeColor, lineWidth: borderWidth + (trackingFinger ? 0.5 : 0))
        )
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
        .offset(dragOffset)
        .opacity(1.0 - Double(abs(dragOffset.width) / 150.0))
        .contentShape(RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous))
        .gesture(cardDragGesture)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title). \(card.subtitle ?? "")")
        .accessibilityHint(SakuraL10n.tr("notif.card.swipeDismissA11y"))
        .accessibilityAddTraits(.isButton)
        .fontDesign(theme.notificationFontDesign())
        .fontWeight(theme.notificationFontWeight())
        .environment(\.dynamicTypeSize, dynamicTypeSize(for: theme.notificationTextScale))
    }
}
