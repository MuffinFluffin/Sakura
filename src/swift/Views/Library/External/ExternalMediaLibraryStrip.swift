// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

// all-media strip for the AirConsole library. shows the full media library
// (recordings + screenshots, newest first) regardless of which game they
// were captured from. sits below the per-game ExternalGameClipsStrip so
// users can jump into media without leaving the library shell.
struct ExternalMediaLibraryStrip: View {
    let items: [MediaItem]
    @Binding var focusedIndex: Int
    var isFocused: Bool
    var onOpen: (MediaItem) -> Void

    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if items.isEmpty {
                emptyRow
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                tile(for: item, index: index)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: focusedIndex) { _, newValue in
                        guard isFocused, items.indices.contains(newValue) else { return }
                        withAnimation(theme.libraryCarouselScrollAnimation) {
                            proxy.scrollTo(items[newValue].id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme.accentColor())
            Text(SakuraL10n.tr("library.external.section.allMedia"))
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
            if !items.isEmpty {
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.accentColor().opacity(0.8)))
            }
            Spacer(minLength: 0)
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
            Text(SakuraL10n.tr("library.external.allMedia.empty"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func tile(for item: MediaItem, index: Int) -> some View {
        let tileFocus = isFocused && focusedIndex == index
        Button {
            SFXManager.shared.play(.confirm)
            onOpen(item)
        } label: {
            ExternalClipTileContent(item: item)
                .frame(width: 360, height: 204)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.glassTileStroke(colorScheme, isFocused: tileFocus), lineWidth: 1)
                )
                .sakuraFocusRing(
                    isFocused: tileFocus,
                    controllerActive: true,
                    cornerRadius: 12,
                    tvMode: tileFocus
                )
        }
        .buttonStyle(.plain)
    }
}
