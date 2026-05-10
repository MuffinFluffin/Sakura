// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import AVFoundation
import UIKit

struct MediaBrowserRoot: View {
    @StateObject private var store = MediaLibraryStore.shared
    @Bindable private var theme = ThemeManager.shared
    @Bindable private var settings = SettingsStore.shared
    @State private var appState = AppState.shared
    @State private var gamepad = GamepadNavigation.shared
    @State private var focus = TileFocus.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTopIndex = AppState.shared.currentTopIndex
    @State private var viewerItem: MediaItem?
    @State private var contextItem: MediaItem?
    @State private var showContextSheet = false
    @State private var pendingDelete: MediaItem?
    @State private var showDeleteConfirm = false
    @State private var pendingClearKind: MediaKind?
    @State private var showClearConfirm = false
    @Environment(\.sakuraRenderingOnExternalDisplay) private var onTV

    private var orderedIDs: [String] {
        var ids: [String] = ["media.summary.screenshot", "media.summary.recording", "media.summary.background"]
        for item in store.items.filter({ $0.kind == .screenshot }) { ids.append(tileID(item)) }
        for item in store.items.filter({ $0.kind == .recording }) { ids.append(tileID(item)) }
        for item in store.items.filter({ $0.kind == .background }) { ids.append(tileID(item)) }
        return ids
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(
                selectedIndex: $selectedTopIndex,
                controllerFocusActive: gamepad.shellNavInputActive && focus.region == .topBar,
                wideChrome: onTV,
                leadingTitle: SakuraL10n.tr("media.title"),
                activateItem: { idx in
                    appState.activateTopIndex(idx)
                }
            )

            content

            if !settings.bottomActionBarHidden {
                mediaActionBadgesHStack
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .onAppear {
            gamepad.enterLibrary()
            store.refresh()
            selectedTopIndex = appState.currentTopIndex
            focus.setPage(sections: makeSections(), columnHint: 3)
            if gamepad.shellNavInputActive {
                focus.exitToTopBar()
            } else {
                focus.enterContent()
            }
        }
        .onDisappear {
            // don't leave; next screen claims context in its onAppear
        }
        .onChange(of: appState.currentTopIndex) { _, newValue in
            selectedTopIndex = newValue
        }
        .onChange(of: store.items.count) { _, _ in
            focus.setPage(sections: makeSections(), columnHint: 3)
        }
        .onChange(of: gamepad.actionID) { _, _ in
            handleGamepadAction()
        }
        .onChange(of: gamepad.hasHardwareKeyboard) { _, _ in
            if gamepad.shellNavInputActive {
                focus.exitToTopBar()
            } else {
                focus.enterContent()
            }
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaFullscreenViewer(
                store: store,
                initialItem: item,
                onLoadState: { it, which in
                    loadAttachedState(it, which: which)
                },
                onSetBackground: { it in
                    if store.setAsBackground(item: it) {
                        SakuraNotificationCenter.shared.postSettingChange(
                            title: SakuraL10n.tr("media.toast.savedAsBackground"),
                            detail: nil
                        )
                    }
                },
                onDelete: { it in
                    pendingDelete = it
                    showDeleteConfirm = true
                }
            )
        }
        .confirmationDialog(
            contextItem.flatMap { $0.url.lastPathComponent } ?? "",
            isPresented: $showContextSheet,
            titleVisibility: .visible
        ) {
            if let it = contextItem {
                Button(SakuraL10n.tr("media.viewer.share")) { shareItem(it) }
                if it.kind != .background {
                    Button(SakuraL10n.tr("media.viewer.setBackground")) {
                        if store.setAsBackground(item: it) {
                            SakuraNotificationCenter.shared.postSettingChange(
                                title: SakuraL10n.tr("media.toast.savedAsBackground"),
                                detail: nil
                            )
                        }
                    }
                }
                if let s = it.sidecar?.savedStateAtStart {
                    Button(SakuraL10n.tr("media.viewer.loadStart")) {
                        loadAttachedState(it, which: s)
                    }
                }
                if let e = it.sidecar?.savedStateAtEnd {
                    Button(SakuraL10n.tr("media.viewer.loadEnd")) {
                        loadAttachedState(it, which: e)
                    }
                }
                Button(SakuraL10n.tr("media.viewer.delete"), role: .destructive) {
                    pendingDelete = it
                    showDeleteConfirm = true
                }
                Button(SakuraL10n.tr("common.cancel"), role: .cancel) {}
            }
        }
        .alert(SakuraL10n.tr("media.deleteAll.confirmTitle"), isPresented: $showDeleteConfirm) {
            Button(SakuraL10n.tr("common.cancel"), role: .cancel) {}
            Button(SakuraL10n.tr("media.viewer.delete"), role: .destructive) {
                if let it = pendingDelete {
                    store.delete(it)
                    SakuraNotificationCenter.shared.postSettingChange(
                        title: SakuraL10n.tr("media.toast.deleted"),
                        detail: nil
                    )
                    pendingDelete = nil
                }
            }
        } message: {
            EmptyView()
        }
        .alert(SakuraL10n.tr("media.deleteAll.confirmTitle"), isPresented: $showClearConfirm) {
            Button(SakuraL10n.tr("common.cancel"), role: .cancel) {}
            Button(SakuraL10n.tr("media.viewer.delete"), role: .destructive) {
                if let kind = pendingClearKind {
                    store.deleteAll(kind: kind)
                    pendingClearKind = nil
                }
            }
        } message: {
            EmptyView()
        }
    }

    private var focusedMediaItem: MediaItem? {
        guard let id = focus.focusedID else { return nil }
        return mediaItem(forID: id)
    }

    @ViewBuilder
    private var mediaActionBadgesHStack: some View {
        let kb = gamepad.hasHardwareKeyboard
        HStack(alignment: .center, spacing: 8) {
            PSActionBadge(
                systemName: "l1.button.roundedbottom.horizontal",
                psIcon: nil,
                psFallback: nil,
                circleGlyphText: kb ? SakuraL10n.tr("keyboard.shell.brackets") : nil,
                shoulderSymbol: kb ? nil : "l1.button.roundedbottom.horizontal",
                shoulderSymbolSecond: kb ? nil : "r1.button.roundedbottom.horizontal",
                title: SakuraL10n.tr("library.hint.pages"),
                tint: theme.color(forKey: "yellow"),
                libraryFooterCompact: true
            )

            PSActionBadge(
                systemName: "checkmark",
                psIcon: kb ? nil : "cross",
                psFallback: kb ? SakuraL10n.tr("keyboard.shell.enter") : gamepad.confirmLabel,
                title: SakuraL10n.tr("media.bottom.open"),
                tint: theme.color(forKey: "blue"),
                libraryFooterCompact: true
            ) {
                if let item = focusedMediaItem { openItem(item) }
            }

            if let item = focusedMediaItem, item.kind != .background {
                PSActionBadge(
                    systemName: "photo.fill.on.rectangle.fill",
                    psIcon: kb ? nil : "square",
                    psFallback: kb ? SakuraL10n.tr("keyboard.shell.j") : gamepad.secondaryLabel,
                    title: SakuraL10n.tr("media.viewer.setBackground"),
                    tint: theme.color(forKey: "pink"),
                    libraryFooterCompact: true
                ) {
                    if store.setAsBackground(item: item) {
                        SakuraNotificationCenter.shared.postSettingChange(
                            title: SakuraL10n.tr("media.toast.savedAsBackground"),
                            detail: nil
                        )
                    }
                }
            }

            if let item = focusedMediaItem,
               item.sidecar?.savedStateAtStart != nil || item.sidecar?.savedStateAtEnd != nil {
                PSActionBadge(
                    systemName: "memorychip",
                    psIcon: kb ? nil : "triangle",
                    psFallback: kb ? SakuraL10n.tr("keyboard.shell.l") : gamepad.tertiaryLabel,
                    title: SakuraL10n.tr("media.viewer.loadSaveState"),
                    tint: theme.color(forKey: "green"),
                    libraryFooterCompact: true
                ) {
                    let s = item.sidecar
                    if let leaf = s?.savedStateAtStart ?? s?.savedStateAtEnd {
                        loadAttachedState(item, which: leaf)
                    }
                }
            }

            if let item = focusedMediaItem {
                PSActionBadge(
                    systemName: "trash",
                    psIcon: kb ? nil : "circle",
                    psFallback: kb ? SakuraL10n.tr("keyboard.shell.esc") : gamepad.backLabel,
                    title: SakuraL10n.tr("media.viewer.delete"),
                    tint: theme.color(forKey: "red"),
                    libraryFooterCompact: true
                ) {
                    pendingDelete = item
                    showDeleteConfirm = true
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 48))
                    .foregroundStyle(theme.glassTextTertiary(colorScheme).opacity(0.7))
                Text(SakuraL10n.tr("media.empty"))
                    .font(.headline)
                    .foregroundStyle(theme.glassTextSecondary(colorScheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SettingsScroll {
                summarySection
                screenshotsSection
                recordingsSection
                backgroundsSection
            }
        }
    }

    private var summarySection: some View {
        SettingSection(title: SakuraL10n.tr("media.title")) {
            TileGrid {
                MediaSummaryTile(
                    id: "media.summary.screenshot",
                    icon: "camera.fill",
                    title: SakuraL10n.tr("media.summary.screenshots"),
                    bytes: store.totalBytes(kind: .screenshot),
                    onClear: {
                        pendingClearKind = .screenshot
                        showClearConfirm = true
                    }
                )
                MediaSummaryTile(
                    id: "media.summary.recording",
                    icon: "video.fill",
                    title: SakuraL10n.tr("media.summary.recordings"),
                    bytes: store.totalBytes(kind: .recording),
                    onClear: {
                        pendingClearKind = .recording
                        showClearConfirm = true
                    }
                )
                MediaSummaryTile(
                    id: "media.summary.background",
                    icon: "photo.fill.on.rectangle.fill",
                    title: SakuraL10n.tr("media.summary.backgrounds"),
                    bytes: store.totalBytes(kind: .background),
                    onClear: nil
                )
            }
        }
    }

    @ViewBuilder
    private var screenshotsSection: some View {
        let items = store.items.filter { $0.kind == .screenshot }
        if !items.isEmpty {
            SettingSection(title: SakuraL10n.tr("media.section.screenshots")) {
                MediaThumbnailGrid(items: items, onTap: openItem, onContext: openContext)
            }
        }
    }

    @ViewBuilder
    private var recordingsSection: some View {
        let items = store.items.filter { $0.kind == .recording }
        if !items.isEmpty {
            SettingSection(title: SakuraL10n.tr("media.section.recordings")) {
                MediaThumbnailGrid(items: items, onTap: openItem, onContext: openContext)
            }
        }
    }

    @ViewBuilder
    private var backgroundsSection: some View {
        let items = store.items.filter { $0.kind == .background }
        if !items.isEmpty {
            SettingSection(title: SakuraL10n.tr("media.section.backgrounds")) {
                MediaThumbnailGrid(items: items, onTap: openItem, onContext: openContext)
            }
        }
    }

    private func makeSections() -> [[String]] {
        let summary = ["media.summary.screenshot", "media.summary.recording", "media.summary.background"]
        let screenshots = store.items.filter { $0.kind == .screenshot }.map(tileID)
        let recordings = store.items.filter { $0.kind == .recording }.map(tileID)
        let backgrounds = store.items.filter { $0.kind == .background }.map(tileID)
        var sections: [[String]] = [summary]
        if !screenshots.isEmpty { sections.append(screenshots) }
        if !recordings.isEmpty { sections.append(recordings) }
        if !backgrounds.isEmpty { sections.append(backgrounds) }
        return sections
    }

    private func handleGamepadAction() {
        guard appState.currentScreen == .mediaBrowser else { return }
        guard viewerItem == nil else { return }
        guard !showContextSheet, !showDeleteConfirm, !showClearConfirm else { return }
        if gamepad.context != .library { gamepad.enterLibrary() }
        guard let action = gamepad.lastAction else { return }

        switch action {
        case .moveLeft:
            if focus.region == .content {
                focus.move(-1)
            } else if focus.region == .topBar {
                let count = SettingsPage.allCases.count + 2
                let next = (selectedTopIndex - 1 + count) % count
                if next != selectedTopIndex {
                    selectedTopIndex = next
                    SFXManager.shared.play(.navigate)
                }
            }
        case .moveRight:
            if focus.region == .content {
                focus.move(1)
            } else if focus.region == .topBar {
                let count = SettingsPage.allCases.count + 2
                let next = (selectedTopIndex + 1) % count
                if next != selectedTopIndex {
                    selectedTopIndex = next
                    SFXManager.shared.play(.navigate)
                }
            }
        case .moveUp:
            if focus.region == .content {
                if !focus.moveRow(-1) {
                    focus.exitToTopBar()
                    SFXManager.shared.play(.navigate)
                }
            }
        case .moveDown:
            if focus.region == .topBar {
                focus.enterContent()
                SFXManager.shared.play(.navigate)
            } else {
                _ = focus.moveRow(1)
            }
        case .confirm:
            if focus.region == .topBar {
                SFXManager.shared.play(.confirm)
                appState.activateTopIndex(selectedTopIndex)
            } else if let id = focus.focusedID {
                if let item = mediaItem(forID: id) {
                    SFXManager.shared.play(.confirm)
                    openItem(item)
                } else {
                    focus.confirm()
                }
            }
        case .secondary:
            if let id = focus.focusedID, let item = mediaItem(forID: id) {
                openContext(item)
            }
        case .back:
            if focus.region == .content {
                focus.exitToTopBar()
                SFXManager.shared.play(.back)
            } else {
                SFXManager.shared.play(.back)
                appState.returnToMenu()
            }
        case .shoulderLeft:
            SFXManager.shared.play(.navigate)
            appState.cycleTopSection(delta: -1)
        case .shoulderRight:
            SFXManager.shared.play(.navigate)
            appState.cycleTopSection(delta: 1)
        default:
            break
        }
    }

    private func openItem(_ item: MediaItem) {
        if item.kind == .background {
            if store.setAsBackground(item: item) {
                SakuraNotificationCenter.shared.postSettingChange(
                    title: SakuraL10n.tr("media.toast.savedAsBackground"),
                    detail: nil
                )
            }
            return
        }
        viewerItem = item
    }

    private func openContext(_ item: MediaItem) {
        contextItem = item
        showContextSheet = true
    }

    private func mediaItem(forID id: String) -> MediaItem? {
        store.items.first { tileID($0) == id }
    }

    private func tileID(_ item: MediaItem) -> String {
        "media.item.\(item.url.lastPathComponent)"
    }

    private func shareItem(_ item: MediaItem) {
        let av = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let rootVC = scenes.first?.keyWindow?.rootViewController {
            av.popoverPresentationController?.sourceView = rootVC.view
            av.popoverPresentationController?.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 1, height: 1)
            av.popoverPresentationController?.permittedArrowDirections = []
            rootVC.present(av, animated: true)
        }
    }

    private func loadAttachedState(_ item: MediaItem, which leaf: String) {
        viewerItem = nil
        gamepad.enterLibrary()

        guard settings.saveStatesEnabled else {
            SakuraNotificationCenter.shared.postSettingChange(
                title: SakuraL10n.tr("media.toast.needGameForAttachedState"),
                detail: nil
            )
            return
        }
        let metaDir = item.url.deletingLastPathComponent().appendingPathComponent(".metadata")
        let fullPath = metaDir.appendingPathComponent(leaf).path
        guard FileManager.default.fileExists(atPath: fullPath) else {
            SakuraNotificationCenter.shared.postSettingChange(
                title: SakuraL10n.tr("media.toast.attachedSaveLoadFailed"),
                detail: nil
            )
            return
        }
        let isoHint = item.sidecar?.isoName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !isoHint.isEmpty else {
            SakuraNotificationCenter.shared.postSettingChange(
                title: SakuraL10n.tr("media.toast.needGameForAttachedState"),
                detail: nil
            )
            return
        }
        // defer actual load so the fullscreen cover finishes dismissing first;
        // calling loadSaveStateBytes synchronously while the cover is still
        // tearing down racy with the emulator's audio reset and produced the
        // freeze + locked-controller report.
        DispatchQueue.main.async {
            if SakuraBridge.isEmulationRunning() {
                let cur = SakuraBridge.currentISOPath() ?? ""
                if !cur.isEmpty, PendingMediaAttachedSaveKeys.isoMatchesStoredBoot(launchingOrBootINI: cur, storedBootPathOrISOFromSidecar: isoHint) {
                    let ok = SakuraBridge.loadSaveStateBytes(fromPath: fullPath)
                    if !ok {
                        SakuraNotificationCenter.shared.postSettingChange(
                            title: SakuraL10n.tr("media.toast.attachedSaveLoadFailed"),
                            detail: nil
                        )
                    }
                    return
                }
            }
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "sakura.library.pendingLoadSlot")
            defaults.removeObject(forKey: "sakura.library.pendingLoadISO")
            defaults.set(fullPath, forKey: PendingMediaAttachedSaveKeys.pathDefaultsKey)
            defaults.set(isoHint, forKey: PendingMediaAttachedSaveKeys.expectedISODefaultsKey)
            appState.playGame(isoName: isoHint)
        }
    }
}

// MARK: - Summary tile

struct MediaSummaryTile: View {
    let id: String
    let icon: String
    let title: String
    let bytes: UInt64
    var onClear: (() -> Void)?

    @State private var focus = TileFocus.shared
    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private var isFocused: Bool {
        focus.focusedID == id && focus.region == .content
    }

    private var tileMinHeight: CGFloat { theme.largerTouchTargets ? 140 : 112 }

    private var strokeWidth: CGFloat {
        if theme.highContrastOutlines { return isFocused ? 3 : 2 }
        if theme.increaseContrast { return isFocused ? 3 : 1.5 }
        return isFocused ? 2.5 : 1
    }

    var body: some View {
        Button(action: {
            focus.focusFromTouch(id: id)
            SFXManager.shared.play(.confirm)
            onClear?()
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(0.9))
                    Spacer(minLength: 0)
                    if onClear != nil {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.glassTextTertiary(colorScheme))
                    }
                }

                Spacer(minLength: 0)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.05)
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(PlaytimeStore.formatByteCount(bytes))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: tileMinHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .fill(theme.glassTileBackground(colorScheme, isFocused: isFocused))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .stroke(theme.glassTileStroke(colorScheme, isFocused: isFocused), lineWidth: strokeWidth)
            )
            .shadow(
                color: isFocused ? theme.glassTileShadow(colorScheme, isFocused: true) : .clear,
                radius: isFocused ? 10 : 0
            )
            .compositingGroup()
            .scaleEffect(isFocused && !theme.reduceMotion ? 1.02 : 1.0)
            .animation(theme.reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
        .id(id)
        .background(TileColumnReporter(id: id))
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == id && focus.region == .content {
                onClear?()
            }
        }
    }
}

// MARK: - Thumbnail grid + tile

struct MediaThumbnailGrid: View {
    let items: [MediaItem]
    let onTap: (MediaItem) -> Void
    let onContext: (MediaItem) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnCount: Int = 3

    private var minWidth: CGFloat {
        horizontalSizeClass == .compact ? 148 : 200
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minWidth), spacing: 14)],
            spacing: 14
        ) {
            ForEach(items) { item in
                MediaThumbnailTile(item: item, onTap: onTap, onContext: onContext)
            }
        }
        .environment(\.sakuraGridColumnCount, columnCount)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            let measured = max(1, Int(floor((width + 14) / (minWidth + 14))))
            if measured != columnCount {
                columnCount = measured
            }
        }
    }
}

struct MediaThumbnailTile: View {
    let item: MediaItem
    let onTap: (MediaItem) -> Void
    let onContext: (MediaItem) -> Void

    @State private var focus = TileFocus.shared
    @State private var theme = ThemeManager.shared
    @State private var thumbnail: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    private var id: String { "media.item.\(item.url.lastPathComponent)" }

    private var isFocused: Bool {
        focus.focusedID == id && focus.region == .content
    }

    private var strokeWidth: CGFloat {
        if theme.highContrastOutlines { return isFocused ? 3 : 2 }
        if theme.increaseContrast { return isFocused ? 3 : 1.5 }
        return isFocused ? 2.5 : 1
    }

    private var hasAttachedState: Bool {
        guard let s = item.sidecar else { return false }
        return s.savedStateAtStart != nil || s.savedStateAtEnd != nil
    }

    private var mediaCaptionInstant: Date {
        item.sidecar?.capturedAt ?? item.modified
    }

    private var mediaCaptionTimeText: String {
        mediaCaptionInstant.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        Button(action: {
            focus.focusFromTouch(id: id)
            SFXManager.shared.play(.confirm)
            onTap(item)
        }) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .fill(theme.glassTileBackground(colorScheme, isFocused: isFocused))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let thumb = thumbnail {
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            ProgressView()
                                .tint(theme.glassTextSecondary(colorScheme))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous))

                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if item.isVideo {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            if hasAttachedState {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            Spacer(minLength: 0)
                            if let dur = item.sidecar?.durationSeconds {
                                Text(PlaytimeStore.formatDuration(dur))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                            }
                            Text(PlaytimeStore.formatByteCount(item.sizeBytes))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        Text(mediaCaptionTimeText)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.55), .black.opacity(0.0)],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .stroke(theme.glassTileStroke(colorScheme, isFocused: isFocused), lineWidth: strokeWidth)
            )
            .shadow(
                color: isFocused ? theme.glassTileShadow(colorScheme, isFocused: true) : .clear,
                radius: isFocused ? 10 : 0
            )
            .compositingGroup()
            .scaleEffect(isFocused && !theme.reduceMotion ? 1.02 : 1.0)
            .animation(theme.reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
        .id(id)
        .contextMenu {
            Button {
                onContext(item)
            } label: {
                Label(SakuraL10n.tr("media.viewer.share"), systemImage: "ellipsis.circle")
            }
        }
        .onLongPressGesture {
            onContext(item)
        }
        .background(TileColumnReporter(id: id))
        .task {
            loadThumbnail()
        }
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == id && focus.region == .content {
                onTap(item)
            }
        }
    }

    private func loadThumbnail() {
        if item.isVideo {
            Task.detached(priority: .background) {
                let asset = AVURLAsset(url: item.url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 512, height: 512)
                if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                    let uiImage = UIImage(cgImage: cgImage)
                    await MainActor.run { self.thumbnail = uiImage }
                }
            }
        } else {
            Task.detached(priority: .background) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512
                ]
                if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                   let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    let uiImage = UIImage(cgImage: cgImage)
                    await MainActor.run { self.thumbnail = uiImage }
                }
            }
        }
    }
}
