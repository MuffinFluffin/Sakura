// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct RatingPromptView: View {
    let onYes: () -> Void
    let onNo: () -> Void

    @State private var theme = ThemeManager.shared

    private var tintColor: Color { theme.accentColor() }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { /* eat taps */ }

            GeometryReader { geometry in
                VStack(spacing: 18) {
                    Spacer(minLength: 0)

                    VStack(spacing: 22) {
                        ZStack {
                            Circle()
                                .fill(tintColor.opacity(0.18))
                                .frame(width: 96, height: 96)
                            Image(systemName: "star.fill")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(tintColor)
                        }
                        .padding(.top, 4)

                        VStack(spacing: 10) {
                            Text(SakuraL10n.tr("rating.prompt.title"))
                                .font(.title2.weight(.bold))
                                .foregroundStyle(theme.glassTextPrimary(.dark))
                                .multilineTextAlignment(.center)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(SakuraL10n.tr("rating.prompt.message"))
                                .font(.body)
                                .foregroundStyle(theme.glassTextSecondary(.dark))
                                .multilineTextAlignment(.center)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: min(520, max(0, geometry.size.width - 48)))
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 0)

                    VStack(spacing: 12) {
                        Button(action: onYes) {
                            Text(SakuraL10n.tr("rating.prompt.yes"))
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(theme.glassTextPrimary(.dark))
                                .frame(maxWidth: 320)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                                        .fill(tintColor.opacity(0.28))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                                        .stroke(tintColor.opacity(0.6), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)

                        Button(action: onNo) {
                            Text(SakuraL10n.tr("rating.prompt.no"))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(theme.glassTextSecondary(.dark))
                                .frame(maxWidth: 320)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                                        .fill(theme.glassTextPrimary(.dark).opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                                        .stroke(theme.glassTextPrimary(.dark).opacity(0.18), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, max(30, geometry.safeAreaInsets.bottom + 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
