// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MusicSection: View {
    @State private var player = MusicPlayer.shared
    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showImporter: Bool = false
    @State private var downloadingSlugs: Set<String> = []
    @State private var downloadError: String?

    private static let importableAudioTypes: [UTType] = {
        let exts = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "caf"]
        var types = exts.compactMap { UTType(filenameExtension: $0) }
        if !types.contains(.audio) { types.append(.audio) }
        return types
    }()

    var body: some View {
        SettingSection(title: SakuraL10n.tr("ui.section.music")) {
            nowPlayingCard
            SliderTile(
                id: "music.bgmVolume",
                icon: "speaker.wave.2.fill",
                title: SakuraL10n.tr("music.tile.bgmVolume"),
                value: Binding(
                    get: { Double(player.volume) },
                    set: { player.volume = Float($0) }
                ),
                range: 0...1,
                step: 0.05,
                format: { String(format: "%.0f%%", $0 * 100) }
            )
            TileGrid {
                SettingTile(
                    id: "music.playpause",
                    icon: player.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                    title: SakuraL10n.tr("music.tile.playbackTitle"),
                    value: player.isPlaying ? SakuraL10n.tr("music.tile.playing") : SakuraL10n.tr("music.tile.paused"),
                    valueTint: player.isPlaying ? theme.color(forKey: "green") : theme.glassTextSecondary(colorScheme)
                ) {
                    player.toggleFromUser()
                }
                SettingTile(
                    id: "music.next",
                    icon: "forward.fill",
                    title: SakuraL10n.tr("music.tile.nextTrack"),
                    value: nextTrackTitle
                ) {
                    player.next()
                }
                SettingTile(
                    id: "music.shuffle",
                    icon: player.shuffleEnabled ? "shuffle.circle.fill" : "shuffle",
                    title: "Shuffle",
                    value: player.shuffleEnabled ? SakuraL10n.tr("common.on") : SakuraL10n.tr("common.off"),
                    valueTint: player.shuffleEnabled ? theme.color(forKey: "green") : theme.glassTextSecondary(colorScheme)
                ) {
                    player.shuffleEnabled.toggle()
                }
                CycleTile(
                    id: "music.loop",
                    icon: loopIcon,
                    title: SakuraL10n.tr("music.tile.loopTile"),
                    options: [
                        (MusicPlayer.LoopMode.off, SakuraL10n.tr("common.off")),
                        (MusicPlayer.LoopMode.all, SakuraL10n.tr("music.loop.all")),
                        (MusicPlayer.LoopMode.one, SakuraL10n.tr("music.loop.one")),
                    ],
                    selection: Binding(
                        get: { player.loopMode },
                        set: { player.loopMode = $0 }
                    )
                )
                SettingTile(
                    id: "music.import",
                    icon: "plus.rectangle.on.folder",
                    title: SakuraL10n.tr("music.tile.importYourMusic"),
                    value: SakuraL10n.tr("common.files")
                ) {
                    showImporter = true
                }
            }

            trackListView

            TileGrid {
                ForEach(missingBuiltinTracks, id: \.slug) { track in
                    SettingTile(
                        id: "music.dl.\(track.slug)",
                        icon: downloadingSlugs.contains(track.slug) ? "arrow.down.circle" : "icloud.and.arrow.down",
                        title: track.title,
                        value: downloadingSlugs.contains(track.slug) ? SakuraL10n.tr("common.downloading") : SakuraL10n.tr("common.download")
                    ) {
                        Task { await download(track) }
                    }
                }
            }

            if let downloadError {
                Text(downloadError)
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
        .sheet(isPresented: $showImporter) {
            MusicDocumentPicker(
                contentTypes: Self.importableAudioTypes,
                allowsMultipleSelection: true,
                onCompletion: { urls in
                    showImporter = false
                    handleImportedURLs(urls)
                }
            )
            .ignoresSafeArea()
        }
    }


    private var nowPlayingCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .fill(theme.accentColor().opacity(0.25))
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.accentColor())
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentTrack?.title ?? SakuraL10n.tr("music.track.emptyTitle"))
                    .font(.headline)
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                Text(player.currentTrack?.artist ?? SakuraL10n.tr("music.track.hintSubtitle"))
                    .font(.caption)
                    .foregroundStyle(theme.glassTextSecondary(colorScheme))

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.glassTextPrimary(colorScheme).opacity(0.12))
                            .frame(height: 3)
                        Capsule()
                            .fill(theme.accentColor())
                            .frame(
                                width: max(0, CGFloat(player.progress) * geo.size.width),
                                height: 3
                            )
                    }
                }
                .frame(height: 3)
                .padding(.top, 4)

                HStack {
                    Text(formatTime(player.currentTime))
                    Spacer()
                    Text(formatTime(player.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                .fill(theme.glassCardFill(colorScheme, isFocused: false))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                .stroke(theme.glassCardStroke(colorScheme, isFocused: false), lineWidth: 1)
        )
    }


    private var trackListView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if player.playlist.isEmpty {
                Text(SakuraL10n.tr("music.emptyPlaylistHint"))
                    .font(.caption)
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
            } else {
                ForEach(Array(player.playlist.enumerated()), id: \.element.slug) { idx, track in
                    trackRow(track: track, index: idx)
                }
            }
        }
    }

    private func trackRow(track: MusicTrack, index: Int) -> some View {
        let isCurrent = player.currentIndex == index
        return HStack(spacing: 10) {
            Image(systemName: isCurrent && player.isPlaying ? "waveform" : "music.note")
                .foregroundStyle(isCurrent ? theme.accentColor() : theme.glassTextSecondary(colorScheme))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                Text(track.artist)
                    .font(.caption2)
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
            }
            Spacer(minLength: 0)
            if track.source == .user {
                Button {
                    SFXManager.shared.play(.back)
                    removeUserTrack(track)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isCurrent
                        ? theme.accentColor().opacity(0.15)
                        : theme.glassCardFill(colorScheme, isFocused: false).opacity(0.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if player.currentIndex != index {
                SFXManager.shared.play(.navigate)
            }
            player.select(at: index)
        }
    }


    private var nextTrackTitle: String {
        guard !player.playlist.isEmpty else { return SakuraL10n.tr("common.emdash") }
        let nextIdx = (player.currentIndex + 1) % player.playlist.count
        return player.playlist[nextIdx].title
    }

    private var loopIcon: String {
        switch player.loopMode {
        case .off: return "repeat"
        case .all: return "repeat.circle.fill"
        case .one: return "repeat.1.circle.fill"
        }
    }

    private var missingBuiltinTracks: [MusicTrack] {
        MusicCatalog.fullCatalog.filter { track in
            !track.isDownloaded
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, !t.isNaN, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @MainActor
    private func download(_ track: MusicTrack) async {
        downloadingSlugs.insert(track.slug)
        downloadError = nil
        defer { downloadingSlugs.remove(track.slug) }
        do {
            _ = try await MusicCatalog.download(track)
            player.refreshPlaylist()
        } catch {
            downloadError = SakuraL10n.trf("music.import.failedFmt", "\(track.title): \(error.localizedDescription)")
        }
    }

    private func handleImportedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let userRoot = MusicCatalog.musicRoot.appendingPathComponent("user")
        try? FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        var firstImportedName: String?
        for url in urls {
            let dest = userRoot.appendingPathComponent(url.lastPathComponent)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                SakuraLogUnified("Music", "Info", "Imported: \(url.lastPathComponent)")
                if firstImportedName == nil { firstImportedName = url.lastPathComponent }
            } catch {
                SakuraLogUnified("Music", "Warning", "Import failed: \(error.localizedDescription)")
                downloadError = SakuraL10n.trf("music.import.failedFmt", error.localizedDescription)
            }
        }
        player.refreshPlaylist()
        SakuraLogUnified("Music", "Info", "import: playlist now has \(player.playlist.count) tracks")
        if let name = firstImportedName,
           let idx = player.playlist.firstIndex(where: { $0.localURL.lastPathComponent == name })
        {
            player.select(at: idx)
        }
        player.play()
    }

    private func removeUserTrack(_ track: MusicTrack) {
        try? FileManager.default.removeItem(at: track.localURL)
        player.refreshPlaylist()
    }
}


private struct MusicDocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onCompletion: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: ([URL]) -> Void

        init(onCompletion: @escaping ([URL]) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion([])
        }
    }
}
