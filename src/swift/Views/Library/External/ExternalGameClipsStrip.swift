// SPDX-License-Identifier: GPL-3.0+

import AVFoundation
import SwiftUI
import UIKit

// horizontal strip of recordings + screenshots for the currently-selected
// game. hidden when the game has no associated media so the right column
// stays clean.
struct ExternalGameClipsStrip: View {
    let game: GameItem?
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
            Image(systemName: "film.stack")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme.accentColor())
            Text(SakuraL10n.tr("library.external.section.clips"))
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
            Image(systemName: "video.slash")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
            Text(SakuraL10n.tr("library.external.clips.empty"))
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
                .frame(width: 380, height: 214)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.glassTileStroke(colorScheme, isFocused: tileFocus), lineWidth: 1)
                )
                .sakuraFocusRing(
                    isFocused: tileFocus,
                    controllerActive: true,
                    cornerRadius: 12
                )
        }
        .buttonStyle(.plain)
    }
}

struct ExternalClipTileContent: View {
    let item: MediaItem

    @State private var theme = ThemeManager.shared
    @State private var thumbnail: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.glassTileBackground(colorScheme, isFocused: false))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .tint(theme.glassTextSecondary(colorScheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            LinearGradient(
                colors: [.black.opacity(0.72), .black.opacity(0.0)],
                startPoint: .bottom, endPoint: .top
            )
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if item.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text(captionTime)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer(minLength: 0)
                    if let dur = item.sidecar?.durationSeconds {
                        Text(PlaytimeStore.formatDuration(dur))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            loadThumbnail()
        }
    }

    private var captionTime: String {
        let d = item.sidecar?.capturedAt ?? item.modified
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private func loadThumbnail() {
        if item.isVideo {
            Task.detached(priority: .background) {
                let asset = AVURLAsset(url: item.url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 640)
                if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                    let ui = UIImage(cgImage: cgImage)
                    await MainActor.run { self.thumbnail = ui }
                }
            }
        } else {
            Task.detached(priority: .background) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                ]
                if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                   let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    let ui = UIImage(cgImage: cgImage)
                    await MainActor.run { self.thumbnail = ui }
                }
            }
        }
    }
}
