// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

// hero column for the AirConsole library: large cover, title, dense metadata
// grid and summary. pure presentation, no input handling or state mutation.
struct ExternalLibraryHero: View {
    let game: GameItem?
    var totalPlaytime: TimeInterval = 0
    var lastPlayed: Date? = nil

    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let game {
            content(for: game)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
            Text(SakuraL10n.tr("library.empty.noGames"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.glassTextSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func content(for game: GameItem) -> some View {
        GeometryReader { geo in
            let hasArt = (CoverAspect.image(for: game.imagePath) != nil)
            // smaller caps than before so the wiki blurb has real estate to
            // breathe. the cover was eating 60%+ of the column and shoving
            // the description off the bottom of the screen.
            let coverHeight: CGFloat = hasArt
                ? max(220, min(460, geo.size.height * 0.46))
                : max(140, min(200, geo.size.height * 0.2))
            // wrap the hero in a vertical scroll so the summary can run long
            // without clipping. on small panels the user can scroll; on big
            // panels it just lays out naturally.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    heroCover(for: game, height: coverHeight, hasArt: hasArt)
                    heroTitle(for: game)
                    heroMetadataGrid(for: game)
                    heroSummary(for: game)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func heroCover(for game: GameItem, height: CGFloat, hasArt: Bool) -> some View {
        let cover: UIImage? = CoverAspect.image(for: game.imagePath)
        if hasArt, let cover {
            Image(uiImage: cover)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(theme.coverArtStroke(colorScheme, isSelected: false), lineWidth: 1)
                )
        } else {
            // compact pill for cover-less games. keeps the layout from feeling
            // like a graveyard of grey placeholders.
            HStack(spacing: 14) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(theme.glassTextSecondary(colorScheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.title.isEmpty ? game.fileName : game.title)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                        .lineLimit(1)
                    Text(game.fileName)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.glassTextTertiary(colorScheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.glassTileBackground(colorScheme, isFocused: false))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(theme.coverArtStroke(colorScheme, isSelected: false), lineWidth: 0.6)
            )
        }
    }

    private func heroTitle(for game: GameItem) -> some View {
        let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = title.isEmpty ? game.fileName : title
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(display)
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.55)
            if game.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(theme.color(forKey: "red"))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func heroMetadataGrid(for game: GameItem) -> some View {
        // Two columns so each value has ~2x the width, letting 22pt text breathe
        // at 4K living-room distances instead of getting `minimumScaleFactor`'d
        // down to 14pt. Previously 3 cols made every value shrink aggressively.
        let columns = [
            GridItem(.flexible(minimum: 160), spacing: 22, alignment: .topLeading),
            GridItem(.flexible(minimum: 160), spacing: 22, alignment: .topLeading),
        ]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            heroMetaCell(
                label: SakuraL10n.tr("library.metadata.released"),
                value: sakuraStripWikiArtifacts(game.releaseDate)
            )
            heroMetaCell(
                label: SakuraL10n.tr("library.metadata.genre"),
                value: sakuraStripWikiArtifacts(game.genre)
            )
            heroMetaCell(
                label: SakuraL10n.tr("library.metadata.developer"),
                value: sakuraStripWikiArtifacts(game.developer)
            )
            heroMetaCell(
                label: SakuraL10n.tr("library.metadata.publisher"),
                value: sakuraStripWikiArtifacts(game.publisher)
            )
            heroMetaCell(
                label: SakuraL10n.tr("library.metadata.size"),
                value: PlaytimeStore.formatByteCount(game.sizeBytes)
            )
            if totalPlaytime >= 1 {
                heroMetaCell(
                    label: SakuraL10n.tr("library.metadata.playtime"),
                    value: PlaytimeStore.formatDuration(totalPlaytime)
                )
            }
            if let last = lastPlayed {
                heroMetaCell(
                    label: SakuraL10n.tr("library.metadata.lastPlayed"),
                    value: PlaytimeStore.formatLastPlayed(last)
                )
            }
        }
    }

    private func heroMetaCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
                .lineLimit(1)
            TranslatedGameMetadataLine(
                englishRaw: value,
                font: .system(size: 24, weight: .semibold, design: .rounded),
                lineLimit: 1,
                // 0.85 floor instead of 0.65. stays legible on narrow columns
                // without collapsing to micro-text when a long value shows up.
                minimumScale: 0.85
            )
            .foregroundStyle(theme.glassTextPrimary(colorScheme))
        }
    }

    @ViewBuilder
    private func heroSummary(for game: GameItem) -> some View {
        let trimmed = game.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.caseInsensitiveCompare("unknown") != .orderedSame {
            // 26pt is couch-legible at 4K. lineLimit 40 is effectively
            // "never truncate". the parent ScrollView handles overflow so
            // the whole wiki blurb is reachable with a flick instead of
            // dead-ending at a hard clip.
            TranslatedGameMetadataLine(
                englishRaw: trimmed,
                font: .system(size: 26, weight: .regular, design: .rounded),
                lineLimit: 40,
                minimumScale: 1.0
            )
            .foregroundStyle(theme.glassTextSecondary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        }
    }
}
