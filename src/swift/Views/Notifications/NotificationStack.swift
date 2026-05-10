// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct NotificationStack: View {
    @State private var center = SakuraNotificationCenter.shared
    @State private var theme = ThemeManager.shared

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: alignmentForPosition().horizontal == .leading ? .leading : .trailing,
                   spacing: 8) {
                ForEach(visibleCards) { card in
                    NotificationCard(card: card, maxWidth: cardWidth(in: geo)) {
                        withAnimation(theme.notificationDismissThrowAnimation) {
                            center.dismiss(id: card.id)
                        }
                    } onOpen: {
                        withAnimation(theme.shellOverlayDismissAnimation) {
                            center.presentFullscreen(card)
                        }
                    }
                    .allowsHitTesting(true)
                    .transition(transitionForPosition())
                }
            }
            .padding(.top, center.positionKey.starts(with: "top") ? 90 : 16)
            .padding([.leading, .trailing, .bottom], 16)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: alignmentForPosition()
            )
        }
        .allowsHitTesting(false)
        .animation(
            theme.animationsReduced ? .none : .spring(response: theme.prefersProMotionUIPacing ? 0.32 : 0.38, dampingFraction: 0.85),
            value: center.cards
        )
        .ignoresSafeArea(.keyboard)
    }

    private var visibleCards: [SakuraNotificationCenter.Card] {
        switch center.positionKey {
        case "topLeading", "topTrailing":
            return Array(center.cards.reversed())
        default:
            return center.cards
        }
    }

    private func alignmentForPosition() -> Alignment {
        switch center.positionKey {
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        default: return .bottomTrailing
        }
    }

    private func transitionForPosition() -> AnyTransition {
        let edge: Edge
        switch center.positionKey {
        case "topLeading", "bottomLeading": edge = .leading
        default: edge = .trailing
        }
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge).combined(with: .opacity)
        )
    }

    private func cardWidth(in geometry: GeometryProxy) -> CGFloat {
        min(360, max(220, geometry.size.width - 32))
    }
}
