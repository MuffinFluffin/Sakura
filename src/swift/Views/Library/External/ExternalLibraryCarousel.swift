// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

/// Horizontal cover rail tuned for TV / AirConsole chrome. Cards are smaller than
/// the handheld carousel so the right column has room for the save-state panel and
/// clips strip below it.
struct ExternalLibraryCarousel: View {
    let games: [GameItem]
    @Binding var selectedFilename: String?
    var controllerActive: Bool
    var onActivate: (GameItem) -> Void
    var onSelectionChange: ((GameItem) -> Void)? = nil

    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    /// Tall card for the focused, art-bearing tile.
    private let focusedHeight: CGFloat = 250
    /// Compressed card for tiles that are not focused, regardless of art.
    private let neighborHeight: CGFloat = 170
    // small chip for cover-less tiles, even when focused. they don't deserve
    // a big slot just to show a grey placeholder.
    private let placeholderHeight: CGFloat = 110
    private let cardSpacing: CGFloat = 16
    private let rowHPadding: CGFloat = 24

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .center, spacing: cardSpacing) {
                    ForEach(games) { game in
                        coverButton(for: game)
                    }
                }
                .padding(.horizontal, rowHPadding)
                .padding(.vertical, 14)
            }
            .tint(theme.accentColor())
            .onAppear {
                scrollToSelection(proxy: proxy, animated: false)
            }
            .onChange(of: selectedFilename) { _, _ in
                scrollToSelection(proxy: proxy, animated: true)
            }
        }
        .frame(height: focusedHeight + 36)
    }

    @ViewBuilder
    private func coverButton(for game: GameItem) -> some View {
        let isSelected = (game.fileName == selectedFilename)
        let cover = CoverAspect.image(for: game.imagePath)
        let hasArt = (cover != nil)
        let aspect: CGFloat = max(0.55, min(1.4, game.coverAspect))
        let height: CGFloat = {
            if !hasArt { return placeholderHeight }
            return isSelected ? focusedHeight : neighborHeight
        }()
        let width: CGFloat = hasArt ? height * aspect : 180
        let dim: Double = (controllerActive && !isSelected) ? 0.55 : 1.0

        Button {
            if isSelected {
                SFXManager.shared.play(.confirm)
                onActivate(game)
            } else {
                SFXManager.shared.play(.navigate)
                withAnimation(theme.libraryCarouselSelectAnimation) {
                    selectedFilename = game.fileName
                }
                onSelectionChange?(game)
            }
        } label: {
            Group {
                if hasArt, let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    placeholderTile(for: game)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(
                color: .black.opacity(isSelected ? 0.45 : 0.22),
                radius: isSelected ? 14 : 5,
                x: 0,
                y: isSelected ? 8 : 2
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.coverArtStroke(colorScheme, isSelected: false), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if game.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.color(forKey: "red"))
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .padding(6)
                }
            }
            .opacity(dim)
            .animation(theme.libraryCarouselSelectAnimation, value: isSelected)
            .animation(theme.libraryCarouselSelectAnimation, value: controllerActive)
            .sakuraFocusRing(
                isFocused: isSelected,
                controllerActive: controllerActive,
                cornerRadius: 12,
                tvMode: controllerActive && isSelected
            )
        }
        .buttonStyle(.plain)
        .id(game.fileName)
    }

    @ViewBuilder
    private func placeholderTile(for game: GameItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.glassTileBackground(colorScheme, isFocused: false))
            HStack(spacing: 10) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(theme.glassTextSecondary(colorScheme))
                Text(game.title.isEmpty ? game.fileName : game.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 10)
        }
    }

    private func scrollToSelection(proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedFilename else { return }
        if animated {
            withAnimation(theme.libraryCarouselScrollAnimation) {
                proxy.scrollTo(selectedFilename, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedFilename, anchor: .center)
        }
    }
}
