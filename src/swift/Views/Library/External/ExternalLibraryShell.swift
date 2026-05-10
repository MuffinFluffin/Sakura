// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

/// Focus regions for the AirConsole library. Kept separate from
/// `LibraryShell.LibraryFocusRegion` so the external layout can evolve without
/// stepping on the handheld shell.
/// D-pad stays fully inside these panels. The top bar is intentionally NOT a
/// D-pad focus target. section switching is exclusively L1/R1 so users never
/// accidentally "escape" the panel they're looking at. This also removes the
/// "everything looks selected" top-bar glow problem.
private enum ExternalLibraryFocus {
    case carousel
    case saveStates
    case clips
    case allMedia
}

/// Root view for the AirConsole / external-display library. Fully independent
/// from `LibraryShell` so the wide-screen layout can be iterated on without
/// dragging the handheld shell along.
struct ExternalLibraryShell: View {
    @State private var appState = AppState.shared
    @State private var gamepad = GamepadNavigation.shared
    @State private var settings = SettingsStore.shared
    @State private var theme = ThemeManager.shared
    @Bindable private var playtime = PlaytimeStore.shared

    @StateObject private var data = ExternalLibraryDataSource.shared
    @StateObject private var media = MediaLibraryStore.shared

    @State private var selectedFilename: String?
    @State private var focus: ExternalLibraryFocus = .carousel
    @State private var focusedSaveSlot: Int = 1
    @State private var focusedClipIndex: Int = 0
    @State private var focusedAllMediaIndex: Int = 0
    @State private var saveStateRefreshToken: Int = 0
    @State private var selectedTopIndex: Int = AppState.shared.currentTopIndex

    @State private var mediaViewerItem: MediaItem?
    @State private var showImportPicker: Bool = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private static let lastSelectedISODefaultsKey = "sakura.external.lastSelectedISO"

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.width < 900 {
                    // not really an "external TV". fall back to the handheld shell so
                    // we don't squish the split layout into a phone-sized window.
                    LibraryShell()
                } else {
                    wideBody(in: geo.size)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: FileImporterTypes.libraryGameImports,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls { FileImportHandler.shared.handleURL(url) }
                data.refresh(force: true)
            case .failure(let err):
                SakuraLogUnified("UI", "Warning", "external import picker failed: \(err.localizedDescription)")
            }
        }
        .fullScreenCover(item: $mediaViewerItem) { item in
            MediaFullscreenViewer(
                store: media,
                initialItem: item,
                onLoadState: { it, which in handleMediaLoadState(it, which: which) },
                onSetBackground: { it in
                    if media.setAsBackground(item: it) {
                        SakuraNotificationCenter.shared.postSettingChange(
                            title: SakuraL10n.tr("media.toast.savedAsBackground"),
                            detail: nil
                        )
                    }
                },
                onDelete: { it in
                    media.delete(it)
                }
            )
        }
        .onAppear {
            gamepad.enterLibrary()
            data.refresh()
            media.refresh()
            selectedTopIndex = appState.currentTopIndex
            restoreSelection()
            syncFocusFromInput()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                data.refresh(force: true)
                media.refresh()
            }
        }
        .onChange(of: data.games) { _, new in
            syncSelection(after: new)
        }
        .onChange(of: data.loadVersion) { _, _ in
            saveStateRefreshToken &+= 1
        }
        .onChange(of: media.items.count) { _, _ in
            focusedClipIndex = 0
            focusedAllMediaIndex = 0
        }
        .onChange(of: selectedFilename) { _, new in
            if let new {
                UserDefaults.standard.set(new, forKey: Self.lastSelectedISODefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastSelectedISODefaultsKey)
            }
            focusedSaveSlot = 1
            focusedClipIndex = 0
        }
        .onChange(of: appState.currentTopIndex) { _, new in
            selectedTopIndex = new
        }
        .onChange(of: gamepad.actionID) { _, _ in
            handleGamepadAction()
        }
        .onChange(of: gamepad.hasHardwareKeyboard) { _, _ in
            syncFocusFromInput()
        }
        .onChange(of: appState.runningGameName) { oldValue, newValue in
            if oldValue != nil, newValue == nil {
                data.refresh(force: true)
                saveStateRefreshToken &+= 1
            }
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func wideBody(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            TopBar(
                selectedIndex: $selectedTopIndex,
                // never show controller-focus glow on the top bar. D-pad doesn't
                // target it and the active section is already implied by which
                // panel (library/media/settings) is rendered.
                controllerFocusActive: false,
                wideChrome: true,
                activateItem: { idx in appState.activateTopIndex(idx) }
            )

            if data.games.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                splitLayout(in: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !settings.bottomActionBarHidden, !data.games.isEmpty {
                ExternalActionBar(
                    game: selectedGame,
                    onPlay: { playGame($0) },
                    onToggleFavorite: { g in data.setFavorite(g.fileName, favorite: !g.isFavorite) },
                    onToggleFastBoot: { settings.fastBoot.toggle() },
                    onImport: { showImportPicker = true }
                )
                .padding(.top, 8)
                .padding(.bottom, max(10, bottomSafeInset() - 2))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .environment(\.dynamicTypeSize, .medium)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
            Text(SakuraL10n.tr("library.empty.noGames"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.glassTextSecondary(colorScheme))
            Text(SakuraL10n.tr("library.empty.formatsHint"))
                .font(.callout)
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func splitLayout(in size: CGSize) -> some View {
        let heroWidth = min(max(size.width * 0.42, 360), 640)
        HStack(alignment: .top, spacing: 28) {
            ExternalLibraryHero(
                game: selectedGame,
                totalPlaytime: selectedGame.map { playtime.totalPlaytime(for: $0.fileName) } ?? 0,
                lastPlayed: selectedGame.flatMap { playtime.lastPlayed(for: $0.fileName) }
            )
            .frame(width: heroWidth)
            .frame(maxHeight: .infinity, alignment: .top)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ExternalLibraryCarousel(
                        games: data.games,
                        selectedFilename: $selectedFilename,
                        controllerActive: gamepad.shellNavInputActive && focus == .carousel,
                        onActivate: { playGame($0) }
                    )

                    if settings.saveStatesEnabled {
                        ExternalSaveStatePanel(
                            game: selectedGame,
                            focusedSlot: $focusedSaveSlot,
                            isFocused: gamepad.shellNavInputActive && focus == .saveStates,
                            refreshToken: saveStateRefreshToken,
                            onLoadSlot: { slot in loadSaveStateSlot(slot) }
                        )
                    }

                    ExternalGameClipsStrip(
                        game: selectedGame,
                        items: currentClipsForSelectedGame,
                        focusedIndex: $focusedClipIndex,
                        isFocused: gamepad.shellNavInputActive && focus == .clips,
                        onOpen: { item in mediaViewerItem = item }
                    )

                    ExternalMediaLibraryStrip(
                        items: recentMediaForLibrary,
                        focusedIndex: $focusedAllMediaIndex,
                        isFocused: gamepad.shellNavInputActive && focus == .allMedia,
                        onOpen: { item in mediaViewerItem = item }
                    )

                    Spacer(minLength: 0)
                }
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived

    private var selectedGame: GameItem? {
        guard let f = selectedFilename else { return nil }
        return data.games.first { $0.fileName == f }
    }

    private var currentClipsForSelectedGame: [MediaItem] {
        guard let g = selectedGame else { return [] }
        return ExternalGameMediaFilter.clipsForGame(g, all: media.items, maxCount: 5)
    }

    /// All-media strip is the user's full library minus background images, capped
    /// so we don't blow out the right column on huge libraries.
    private var recentMediaForLibrary: [MediaItem] {
        Array(media.items
            .filter { $0.kind == .recording || $0.kind == .screenshot }
            .prefix(40))
    }

    // MARK: - Selection

    private func restoreSelection() {
        if let saved = UserDefaults.standard.string(forKey: Self.lastSelectedISODefaultsKey),
           data.games.contains(where: { $0.fileName == saved }) {
            selectedFilename = saved
        } else if selectedFilename == nil {
            selectedFilename = data.games.first?.fileName
        }
    }

    private func syncSelection(after games: [GameItem]) {
        if games.isEmpty {
            selectedFilename = nil
            return
        }
        if let sel = selectedFilename, games.contains(where: { $0.fileName == sel }) {
            return
        }
        if let saved = UserDefaults.standard.string(forKey: Self.lastSelectedISODefaultsKey),
           games.contains(where: { $0.fileName == saved }) {
            selectedFilename = saved
        } else {
            selectedFilename = games.first?.fileName
        }
    }

    private func syncFocusFromInput() {
        guard gamepad.shellNavInputActive else { return }
        // With the top bar out of the D-pad cycle, default focus is always the
        // carousel when the library has games; otherwise pick the first panel
        // that has any content so the user is never parked on an empty region.
        if data.games.isEmpty {
            focus = !recentMediaForLibrary.isEmpty ? .allMedia : .carousel
            return
        }
        switch focus {
        case .carousel, .saveStates, .clips, .allMedia:
            return
        }
    }

    // MARK: - Actions

    private func playGame(_ game: GameItem) {
        appState.playGame(isoName: game.fileName)
    }

    private func loadSaveStateSlot(_ slot: Int) {
        guard let game = selectedGame else { return }
        guard settings.saveStatesEnabled else { return }
        let exists = SakuraBridge.hasSaveState(inSlot: Int32(slot), forISOFileName: game.fileName)
        guard exists else {
            SFXManager.shared.play(.error)
            return
        }
        let d = UserDefaults.standard
        d.set(slot, forKey: "sakura.library.pendingLoadSlot")
        d.set(game.fileName, forKey: "sakura.library.pendingLoadISO")
        appState.playGame(isoName: game.fileName)
    }

    private func handleMediaLoadState(_ item: MediaItem, which leaf: String) {
        mediaViewerItem = nil
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
        DispatchQueue.main.async {
            if SakuraBridge.isEmulationRunning() {
                let cur = SakuraBridge.currentISOPath() ?? ""
                if !cur.isEmpty,
                   PendingMediaAttachedSaveKeys.isoMatchesStoredBoot(launchingOrBootINI: cur, storedBootPathOrISOFromSidecar: isoHint) {
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

    // MARK: - Gamepad

    private func handleGamepadAction() {
        guard appState.currentScreen == .menu else { return }
        guard mediaViewerItem == nil else { return }
        if gamepad.context != .library { gamepad.enterLibrary() }
        guard let action = gamepad.lastAction else { return }

        switch action {
        case .moveLeft:
            handleLeft()
        case .moveRight:
            handleRight()
        case .moveUp:
            handleUp()
        case .moveDown:
            handleDown()
        case .confirm:
            handleConfirm()
        case .back:
            handleBack()
        case .secondary:
            handleSecondary()
        case .tertiary:
            if let g = selectedGame { data.setFavorite(g.fileName, favorite: !g.isFavorite) }
        case .menu:
            showImportPicker = true
        case .shoulderLeft:
            cyclePage(delta: -1)
        case .shoulderRight:
            cyclePage(delta: 1)
        default:
            break
        }
    }

    /// L1/R1 page-cycler. We wrap explicitly between the three top sections
    /// (library / media / settings.first) instead of stepping through every
    /// settings page, which was the source of the "stuck" feeling. users had
    /// to mash the shoulder buttons many times to get back to the library.
    private func cyclePage(delta: Int) {
        SFXManager.shared.play(.navigate)
        let order: [Int] = [0, 1, 2]  // 0=library, 1=media, 2=first settings page
        let current = order.firstIndex(of: appState.currentTopIndex) ?? 0
        let next = ((current + delta) % order.count + order.count) % order.count
        appState.activateTopIndex(order[next])
    }

    private func handleLeft() {
        switch focus {
        case .carousel:
            moveCarousel(-1)
        case .saveStates:
            if focusedSaveSlot > 1 {
                focusedSaveSlot -= 1
                SFXManager.shared.play(.navigate)
            }
        case .clips:
            if focusedClipIndex > 0 {
                focusedClipIndex -= 1
                SFXManager.shared.play(.navigate)
            }
        case .allMedia:
            if focusedAllMediaIndex > 0 {
                focusedAllMediaIndex -= 1
                SFXManager.shared.play(.navigate)
            }
        }
    }

    private func handleRight() {
        switch focus {
        case .carousel:
            moveCarousel(1)
        case .saveStates:
            if focusedSaveSlot < 10 {
                focusedSaveSlot += 1
                SFXManager.shared.play(.navigate)
            }
        case .clips:
            if focusedClipIndex < max(0, currentClipsForSelectedGame.count - 1) {
                focusedClipIndex += 1
                SFXManager.shared.play(.navigate)
            }
        case .allMedia:
            if focusedAllMediaIndex < max(0, recentMediaForLibrary.count - 1) {
                focusedAllMediaIndex += 1
                SFXManager.shared.play(.navigate)
            }
        }
    }

    private func handleUp() {
        switch focus {
        case .carousel:
            // top of the stack. no D-pad escape to the top bar on purpose.
            return
        case .saveStates:
            focus = .carousel
            SFXManager.shared.play(.navigate)
        case .clips:
            focus = settings.saveStatesEnabled ? .saveStates : .carousel
            SFXManager.shared.play(.navigate)
        case .allMedia:
            if !currentClipsForSelectedGame.isEmpty {
                focus = .clips
            } else if settings.saveStatesEnabled {
                focus = .saveStates
            } else {
                focus = .carousel
            }
            SFXManager.shared.play(.navigate)
        }
    }

    private func handleDown() {
        switch focus {
        case .carousel:
            if settings.saveStatesEnabled, selectedGame != nil {
                focus = .saveStates
                SFXManager.shared.play(.navigate)
            } else if !currentClipsForSelectedGame.isEmpty {
                focus = .clips
                SFXManager.shared.play(.navigate)
            } else if !recentMediaForLibrary.isEmpty {
                focus = .allMedia
                SFXManager.shared.play(.navigate)
            }
        case .saveStates:
            if !currentClipsForSelectedGame.isEmpty {
                focus = .clips
                SFXManager.shared.play(.navigate)
            } else if !recentMediaForLibrary.isEmpty {
                focus = .allMedia
                SFXManager.shared.play(.navigate)
            }
        case .clips:
            if !recentMediaForLibrary.isEmpty {
                focus = .allMedia
                SFXManager.shared.play(.navigate)
            }
        case .allMedia:
            return
        }
    }

    private func handleConfirm() {
        switch focus {
        case .carousel:
            if let g = selectedGame {
                SFXManager.shared.play(.confirm)
                playGame(g)
            }
        case .saveStates:
            loadSaveStateSlot(focusedSaveSlot)
        case .clips:
            let clips = currentClipsForSelectedGame
            if clips.indices.contains(focusedClipIndex) {
                SFXManager.shared.play(.confirm)
                mediaViewerItem = clips[focusedClipIndex]
            }
        case .allMedia:
            let all = recentMediaForLibrary
            if all.indices.contains(focusedAllMediaIndex) {
                SFXManager.shared.play(.confirm)
                mediaViewerItem = all[focusedAllMediaIndex]
            }
        }
    }

    /// Back snaps the D-pad focus to the carousel (never the top bar, since the
    /// top bar is no longer a D-pad target).
    private func handleBack() {
        if focus != .carousel {
            focus = .carousel
            SFXManager.shared.play(.back)
        }
    }

    private func handleSecondary() {
        guard let g = selectedGame else { return }
        data.setFavorite(g.fileName, favorite: !g.isFavorite)
    }

    private func moveCarousel(_ delta: Int) {
        let games = data.games
        guard !games.isEmpty else { return }
        let currentIndex = games.firstIndex { $0.fileName == selectedFilename } ?? 0
        let next = min(max(currentIndex + delta, 0), games.count - 1)
        if next != currentIndex {
            selectedFilename = games[next].fileName
            SFXManager.shared.play(.navigate)
        }
    }

    @MainActor
    private func bottomSafeInset() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes
        let scene = scenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow?.safeAreaInsets.bottom ?? 0
    }
}
