// SPDX-License-Identifier: GPL-3.0+

import Combine
import GameController
import SwiftUI
import UniformTypeIdentifiers
import UIKit

fileprivate func sakuraLibraryMetadataLookupKey(fileName: String, serial: String?) -> String {
    if let serial, !serial.isEmpty { return serial }
    let safe = fileName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? fileName
    return "file-\(safe)"
}

fileprivate func sakuraLibraryPayloadIdentityCacheKey(for path: String) -> String? {
    guard let dict = SakuraBridge.libraryPayloadIdentity(forISOPath: path) as? [String: NSNumber],
          let dev = dict["dev"],
          let ino = dict["ino"],
          let sz = dict["size"],
          let sec = dict["mtimeSec"],
          let nsec = dict["mtimeNsec"]
    else { return nil }
    return "\(dev.uint64Value)|\(ino.uint64Value)|\(sz.uint64Value)|\(sec.int64Value)|\(nsec.int64Value)"
}

// MARK: - Game row model

struct GameItem: Identifiable, Hashable {
    var id: String { fileName }
    var fileName: String
    var title: String
    var gameID: String?
    var metadataKey: String
    var imagePath: String?
    var releaseDate: String
    var genre: String
    var developer: String
    var publisher: String
    var summary: String
    var absolutePath: String?
    var sizeBytes: UInt64
    var isFavorite: Bool
    var coverAspect: CGFloat = 0.70
    var libraryDedupKey: String
}

private func sakuraLibraryFormatRank(fileName: String) -> Int {
    let ext = (fileName as NSString).pathExtension.lowercased()
    switch ext {
    case "m3u": return 100
    case "cue", "cua": return 90
    case "chd", "pbp": return 80
    case "iso", "img", "nrg", "mdf", "cdi", "toc", "ccd", "mds": return 70
    case "cso", "zso", "ecm", "gz", "psx": return 65
    case "bin": return 55
    default: return 50
    }
}

private func sakuraLibraryPathDepth(_ fileName: String) -> Int {
    fileName.filter { $0 == "/" }.count
}

internal func sakuraISOListingFingerprint(names: [String], emulationStoppedForMapping: Bool) -> UInt64 {
    var h: UInt64 = 14695981039346656037
    let prime: UInt64 = 1099511628211
    for name in names.sorted() {
        for b in name.utf8 {
            h ^= UInt64(b)
            h &*= prime
        }
        h ^= 0x1f
        h &*= prime
    }
    h ^= UInt64(truncatingIfNeeded: names.count)
    h ^= emulationStoppedForMapping ? 0x9e3779b97f4a7c15 : 0xbf58476d1ce4e5b9
    return h
}

private func sakuraLibraryGameKeepsCandidate(_ candidate: GameItem, over incumbent: GameItem) -> Bool {
    if candidate.isFavorite != incumbent.isFavorite { return candidate.isFavorite }
    let rc = sakuraLibraryFormatRank(fileName: candidate.fileName)
    let ri = sakuraLibraryFormatRank(fileName: incumbent.fileName)
    if rc != ri { return rc > ri }
    if candidate.sizeBytes != incumbent.sizeBytes { return candidate.sizeBytes > incumbent.sizeBytes }
    let dc = sakuraLibraryPathDepth(candidate.fileName)
    let di = sakuraLibraryPathDepth(incumbent.fileName)
    if dc != di { return dc > di }
    return candidate.fileName.localizedStandardCompare(incumbent.fileName) == .orderedAscending
}

internal func sakuraDeduplicatedLibraryGames(_ items: [GameItem]) -> [GameItem] {
    var winner: [String: GameItem] = [:]
    var firstIndex: [String: Int] = [:]
    for (idx, item) in items.enumerated() {
        let k = item.libraryDedupKey
        if winner[k] == nil {
            firstIndex[k] = idx
            winner[k] = item
        } else if let w = winner[k], sakuraLibraryGameKeepsCandidate(item, over: w) {
            winner[k] = item
        }
    }
    let keysSorted = firstIndex.keys.sorted { (a, b) in firstIndex[a, default: 0] < firstIndex[b, default: 0] }
    return keysSorted.compactMap { winner[$0] }
}

internal func sakuraStripWikiArtifacts(_ raw: String) -> String {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return raw }
    if t.contains("{{") || t.contains("}}") || t.contains("[[") || t.contains("]]") || t.contains("'''") {
        return SakuraL10n.tr("metadata.unknown")
    }
    if t.contains("{|") || t.hasPrefix("|") && t.contains("=") && t.count < 48 {
        return SakuraL10n.tr("metadata.unknown")
    }
    return raw
}

// MARK: - Cover aspect cache

internal enum CoverAspect {
    private struct Entry {
        let image: UIImage
        let aspect: CGFloat
    }

    private static let maxEntries = 96
    nonisolated(unsafe) private static var cache: [String: Entry] = [:]
    nonisolated(unsafe) private static var mru: [String] = []
    private static let lock = NSLock()

    private static func removeFromMRUUnlocked(path: String) {
        if let idx = mru.firstIndex(of: path) {
            mru.remove(at: idx)
        }
    }

    private static func touchMRU(path: String) {
        removeFromMRUUnlocked(path: path)
        mru.append(path)
    }

    private static func evictOneLRUIfNeeded(forNewPath path: String) {
        while cache.count >= maxEntries && cache[path] == nil {
            guard let victim = mru.first else {
                cache.removeAll(keepingCapacity: true)
                mru.removeAll(keepingCapacity: true)
                return
            }
            mru.removeFirst()
            cache.removeValue(forKey: victim)
        }
    }

    private static func entry(for path: String) -> Entry? {
        lock.lock()
        if let existing = cache[path] {
            touchMRU(path: path)
            lock.unlock()
            return existing
        }
        lock.unlock()
        guard let img = UIImage(contentsOfFile: path) else { return nil }
        let size = img.size
        let ratio: CGFloat = size.height > 0 ? size.width / size.height : 0.70
        let e = Entry(image: img, aspect: ratio)
        lock.lock()
        evictOneLRUIfNeeded(forNewPath: path)
        cache[path] = e
        touchMRU(path: path)
        lock.unlock()
        return e
    }

    static func aspect(for path: String?) -> CGFloat {
        guard let path else { return 0.70 }
        return entry(for: path)?.aspect ?? 0.70
    }

    static func image(for path: String?) -> UIImage? {
        guard let path else { return nil }
        return entry(for: path)?.image
    }

    static func invalidate(path: String) {
        lock.lock()
        cache.removeValue(forKey: path)
        removeFromMRUUnlocked(path: path)
        lock.unlock()
    }

    static func invalidateAll() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        mru.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

private enum LibraryFocusRegion {
    case topBar
    case games
    case saveSlots
    case media
}

// MARK: - Cover carousel

struct GameCoverCarousel<ContextMenuContent: View>: View {
    let games: [GameItem]
    @Binding var selectedFilename: String?
    var controllerActive = false
    var launchOnTap = false
    @ViewBuilder var coverContextMenu: (GameItem) -> ContextMenuContent
    var onLaunch: ((GameItem) -> Void)?

    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private let vPad: CGFloat = 2
    private let minCardHeight: CGFloat = 96
    private let maxCardHeight: CGFloat = 472
    private let rowSpacing: CGFloat = 18
    private let rowHPadding: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let rawH = max(0, geo.size.height - vPad * 2)
            let cardHeight = min(maxCardHeight, max(minCardHeight, rawH))
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: rowSpacing) {
                            ForEach(games) { game in
                                coverButton(for: game, cardHeight: cardHeight)
                            }
                        }
                        .padding(.horizontal, rowHPadding)
                        .padding(.vertical, vPad)
                    }
                    .tint(theme.accentColor())
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear {
                    scrollToSelection(with: proxy)
                }
                .onChange(of: selectedFilename) { _, _ in
                    scrollToSelection(with: proxy)
                }
            }
        }
    }

    @ViewBuilder
    private func coverButton(for game: GameItem, cardHeight: CGFloat) -> some View {
        let isSelected = (game.fileName == selectedFilename)
        let cardWidth = cardHeight
        Button {
            if launchOnTap {
                SFXManager.shared.play(.confirm)
                withAnimation(theme.libraryCarouselSelectAnimation) {
                    selectedFilename = game.fileName
                }
                onLaunch?(game)
            } else if isSelected {
                SFXManager.shared.play(.confirm)
                onLaunch?(game)
            } else {
                SFXManager.shared.play(.navigate)
                withAnimation(theme.libraryCarouselSelectAnimation) {
                    selectedFilename = game.fileName
                }
            }
        } label: {
            Group {
                if let uiImage = CoverAspect.image(for: game.imagePath) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.3))
                        Image(systemName: "opticaldisc")
                            .font(.system(size: min(40, cardHeight * 0.24), weight: .regular))
                            .foregroundStyle(theme.glassTextSecondary(colorScheme))
                    }
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 4, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        theme.coverArtStroke(colorScheme, isSelected: false),
                        lineWidth: 1
                    )
            )
            .sakuraFocusRing(
                isFocused: isSelected,
                controllerActive: controllerActive,
                cornerRadius: 12
            )
        }
        .buttonStyle(.plain)
        .id(game.fileName)
        .contextMenu {
            coverContextMenu(game)
        }
    }

    private func scrollToSelection(with proxy: ScrollViewProxy) {
        guard let selectedFilename else { return }
        withAnimation(theme.libraryCarouselScrollAnimation) {
            proxy.scrollTo(selectedFilename, anchor: .center)
        }
    }
}

// MARK: - Bottom action badges

struct PSActionBadge: View {
    let systemName: String
    var psIcon: String?
    var psFallback: String?
    var circleGlyphText: String? = nil
    var shoulderSymbol: String? = nil
    var shoulderSymbolSecond: String? = nil
    let title: String
    var tint: Color = .white
    var libraryFooterCompact = false
    var tvMode = false
    var action: (() -> Void)?

    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private var circleSize: CGFloat { tvMode ? 34 : (libraryFooterCompact ? 20 : 22) }
    private var shoulderHeight: CGFloat { tvMode ? 30 : (libraryFooterCompact ? 18 : 20) }
    private var hPad: CGFloat { tvMode ? 20 : (libraryFooterCompact ? 10 : 12) }
    private var vPad: CGFloat { tvMode ? 12 : (libraryFooterCompact ? 6 : 6) }

    var body: some View {
        Button(action: { action?() }) {
            HStack(spacing: tvMode ? 10 : (libraryFooterCompact ? 4 : 6)) {
                glyph
                Text(title)
                    .font(tvMode
                        ? .system(size: 14, weight: .heavy, design: .rounded)
                        : (libraryFooterCompact
                            ? .system(size: 9, weight: .bold, design: .rounded)
                            : .caption2.weight(.bold)))
                    .tracking(tvMode ? 1.0 : (libraryFooterCompact ? 0.3 : 0.8))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(libraryFooterCompact ? 0.72 : 0.65)
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background {
                Group {
                    if theme.materialsReduced {
                        Capsule().fill(Color.black.opacity(0.72))
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .layoutPriority(libraryFooterCompact ? 0 : 1)
    }

    @ViewBuilder
    private var glyph: some View {
        if let shoulderSymbol {
            HStack(spacing: 2) {
                Image(systemName: shoulderSymbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(tint, tint.opacity(0.18))
                    .font(.system(size: shoulderHeight, weight: .semibold))
                    .frame(height: shoulderHeight)
                if let shoulderSymbolSecond {
                    Image(systemName: shoulderSymbolSecond)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(tint, tint.opacity(0.18))
                        .font(.system(size: shoulderHeight, weight: .semibold))
                        .frame(height: shoulderHeight)
                }
            }
        } else {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: circleSize, height: circleSize)
                    .overlay(
                        Circle()
                            .stroke(tint.opacity(0.35), lineWidth: 1)
                    )
                if let circleGlyphText {
                    Text(circleGlyphText)
                        .font(.system(size: tvMode ? 15 : (libraryFooterCompact ? 8 : 10), weight: .heavy, design: .rounded))
                        .foregroundColor(tint)
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                } else if let psIcon = psIcon {
                    if UIImage(systemName: "playstation.\(psIcon)") != nil {
                        Image(systemName: "playstation.\(psIcon)")
                            .font(.system(size: tvMode ? 18 : (libraryFooterCompact ? 10 : 12), weight: .bold))
                            .foregroundColor(tint)
                    } else {
                        Text(psFallback ?? "")
                            .font(.system(size: tvMode ? 18 : (libraryFooterCompact ? 10 : 12), weight: .bold))
                            .foregroundColor(tint)
                    }
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: tvMode ? 17 : (libraryFooterCompact ? 10 : 11), weight: .bold))
                        .foregroundColor(tint)
                }
            }
        }
    }
}

// MARK: - Top bar tab button

struct TopIconMenu: View {
    let systemImage: String
    let caption: String
    var isSelected = false
    var isGamepadFocused = false
    var compact = false
    var wide = false
    let action: () -> Void

    @State private var theme = ThemeManager.shared

    private var chipWidth: CGFloat {
        if wide { return compact ? 96 : 124 }
        return compact ? 48 : 56
    }
    private var chipHeight: CGFloat {
        if wide { return 76 }
        return 44
    }
    private var iconSize: CGFloat {
        if wide { return compact ? 26 : 32 }
        return compact ? 16 : 18
    }
    private var iconFrameWidth: CGFloat {
        if wide { return compact ? 32 : 40 }
        return compact ? 20 : 24
    }
    private var captionFitWidth: CGFloat { max(18, chipWidth - 8 + (compact ? 0 : 2)) }

    private var captionPointSize: CGFloat {
        if wide {
            let n = caption.count
            if n <= 8 { return 13 }
            if n <= 12 { return 12 }
            if n <= 16 { return 11 }
            return 10
        }
        let n = caption.count
        let base: CGFloat = compact ? 8.75 : 9.35
        if n <= 8 { return base + (compact ? 0 : 0.45) }
        if n <= 12 { return base }
        if n <= 16 { return max(7.35, base - 0.95) }
        if n <= 22 { return max(6.75, base - 1.65) }
        return max(6.15, base - 2.15)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: wide ? 6 : 2) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(theme.topBarTextColor())
                    .frame(width: iconFrameWidth, height: wide ? 36 : 22)
                Text(caption)
                    .font(.system(size: captionPointSize, weight: wide ? .semibold : .medium, design: .rounded))
                    .fontDesign(.rounded)
                    .foregroundStyle(theme.topBarCaptionColor().opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .multilineTextAlignment(.center)
                    .frame(width: captionFitWidth, alignment: .center)
            }
            .frame(width: chipWidth + (compact ? 2 : 4), height: chipHeight)
            .padding(.horizontal, compact ? 2 : 3)
            .background(
                RoundedRectangle(cornerRadius: wide ? 18 : 14, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: wide ? 18 : 14, style: .continuous)
                    .stroke(staticStrokeColor, lineWidth: staticStrokeWidth)
            )
            .overlay(alignment: .bottom) {
                if isSelected && !isGamepadFocused {
                    Capsule()
                        .fill(theme.accentColor().opacity(0.85))
                        .frame(width: wide ? 28 : 18, height: wide ? 3 : 2)
                        .offset(y: wide ? -6 : -3)
                }
            }
            .sakuraFocusRing(
                isFocused: isGamepadFocused,
                controllerActive: true,
                cornerRadius: wide ? 18 : 14,
                tvMode: wide
            )
            .contentShape(Rectangle())
            .accessibilityLabel(caption)
            .accessibilityHint(SakuraL10n.trf("accessibility.switchToFmt", caption))
            .accessibilityValue(isSelected ? SakuraL10n.tr("library.shell.tab.selected") : SakuraL10n.tr("library.shell.tab.notSelected"))
        }
        .buttonStyle(.plain)
    }

    private var backgroundFill: Color {
        if isGamepadFocused { return theme.accentColor().opacity(wide ? 0.28 : 0.18) }
        if isSelected { return theme.accentColor().opacity(wide ? 0.10 : 0.14) }
        return .clear
    }

    private var staticStrokeColor: Color {
        if isSelected && !isGamepadFocused { return theme.accentColor().opacity(wide ? 0.35 : 0.6) }
        return .clear
    }

    private var staticStrokeWidth: CGFloat {
        if isSelected && !isGamepadFocused { return wide ? 0.6 : 1 }
        return 0
    }
}

// MARK: - Top bar chrome

struct TopBar: View {
    @Binding var selectedIndex: Int
    @State private var settings = SettingsStore.shared
    @State private var theme = ThemeManager.shared
    var controllerFocusActive = false
    var wideChrome = false
    var leadingButtonTitle: String? = nil
    var leadingButtonAction: (() -> Void)? = nil
    var leadingTitle: String? = nil
    let activateItem: (Int) -> Void

    @State private var clock = Date()
    @State private var batterySnapshot = BatteryInfo.current()
    @State private var connectedPorts: [Int] = []
    @State private var barInnerWidth: CGFloat = TopBar.initialBarInnerWidthGuess()

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let batteryTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var items: [(systemImage: String, caption: String)] {
        [
            ("square.grid.3x3", SakuraL10n.tr("ui.topBar.library")),
            ("photo.on.rectangle", SakuraL10n.tr("media.tab.caption"))
        ] + SettingsPage.allCases.map { ($0.icon, $0.topBarCaption) }
    }

    private var microChrome: Bool {
        barInnerWidth < 680
    }

    private var ultraMicroChrome: Bool {
        barInnerWidth < 420
    }

    private var compactTabStyle: Bool {
        barInnerWidth < 920
    }

    private var hideTrailingDate: Bool {
        barInnerWidth < 560
    }

    private var wordmarkSize: CGFloat {
        if wideChrome { return 36 }
        if barInnerWidth < 340 { return 14 }
        if barInnerWidth < 420 { return 15 }
        if barInnerWidth < 560 { return 17 }
        if barInnerWidth < 720 { return 19 }
        if barInnerWidth < 880 { return 21 }
        return 24
    }

    private var hideBattery: Bool {
        settings.topBarHideBattery
    }

    private var hideMusicPlayer: Bool {
        settings.topBarHideMusic
    }

    @MainActor
    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
        let scene =
            scenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? scenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return nil }
        return scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
    }

    @MainActor
    private static func resolvedChromeTopInset() -> CGFloat {
        guard let win = keyWindow() else { return 32 }
        let e = win.safeAreaInsets
        return max(32, 18 + e.top + max(e.left, e.right) * 0.25)
    }

    @MainActor
    private static func initialBarInnerWidthGuess() -> CGFloat {
        guard let win = keyWindow() else { return 520 }
        return max(200, win.bounds.width - 32)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Group {
                if let leadingButtonTitle {
                    let chipText = theme.topBarTextColor()
                    Button {
                        leadingButtonAction?()
                    } label: {
                        Label(leadingButtonTitle, systemImage: "chevron.left")
                            .font(.headline)
                            .foregroundStyle(chipText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(chipText.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(SakuraL10n.tr("library.shell.backHint"))
                    .padding(.trailing, 10)
                    .fixedSize(horizontal: true, vertical: false)
                } else {
                    leadingWordmark(leadingTitle ?? "SAKURA")
                        .frame(width: TopBar.wordmarkReserveWidth(barInnerWidth: barInnerWidth, wide: wideChrome), alignment: .trailing)
                        .padding(.trailing, 10)
                }
            }
            .layoutPriority(2)

            centerTabsRow(spread: true)
                .frame(height: wideChrome ? 92 : 56)
                .frame(maxWidth: .infinity)
                .layoutPriority(0)

            VStack(alignment: .trailing, spacing: 4) {
                if !hideTrailingDate {
                    Text(clock, format: Self.dateFormat)
                        .font(.system(size: microChrome ? 10 : 13, weight: .semibold, design: .rounded))
                        .fontDesign(.rounded)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.topBarCaptionColor().opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .accessibilityLabel(clock.formatted(Self.dateFormat))
                }

                HStack(alignment: .center, spacing: 6) {
                    ForEach(connectedPorts, id: \.self) { port in
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: microChrome ? 11 : 13, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(theme.topBarCaptionColor().opacity(0.95))
                            .accessibilityLabel(SakuraL10n.trf("library.shell.controllerPortA11yFmt", port + 1))
                    }
                    if !hideBattery {
                        batteryBadge
                    }
                    Text(clock, style: .time)
                        .font(.system(size: microChrome ? 13 : 17, weight: .black, design: .rounded))
                        .fontDesign(.rounded)
                        .fontWeight(.black)
                        .monospacedDigit()
                        .foregroundStyle(theme.topBarTextColor().opacity(0.94))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .accessibilityLabel(SakuraL10n.trf("library.a11y.timePrefix", clock.formatted(date: .omitted, time: .shortened)))
                }

                if !hideMusicPlayer && !ultraMicroChrome {
                    TopBarMusicBar()
                        .frame(maxWidth: microChrome ? 180 : 260, alignment: .trailing)
                }
            }
            .padding(.leading, 10)
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, Self.resolvedChromeTopInset())
        .padding(.bottom, 10)
        .onGeometryChange(for: CGFloat.self, of: { proxy in proxy.size.width }, action: { barInnerWidth = $0 })
        .onReceive(clockTimer) { clock = $0 }
        .onReceive(batteryTimer) { _ in batterySnapshot = BatteryInfo.current() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batterySnapshot = BatteryInfo.current()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            batterySnapshot = BatteryInfo.current()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshPorts() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refreshPorts() }
        .onReceive(NotificationCenter.default.publisher(for: .sakuraControllerPortAssignmentsChanged)) { _ in refreshPorts() }
        .onAppear {
            BatteryInfo.enableMonitoring()
            batterySnapshot = BatteryInfo.current()
            refreshPorts()
            if batterySnapshot.level < 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    batterySnapshot = BatteryInfo.current()
                }
            }
        }
    }
    
    private func refreshPorts() {
        let a = ControllerPortAssigner.shared
        connectedPorts = [0, 1].compactMap { a.liveByPort[$0] == nil ? nil : $0 }
    }

    @ViewBuilder
    private func centerTabsRow(spread: Bool = false) -> some View {
        HStack(spacing: spread ? 0 : 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                TopIconMenu(
                    systemImage: item.systemImage,
                    caption: item.caption,
                    isSelected: selectedIndex == index,
                    isGamepadFocused: controllerFocusActive && selectedIndex == index,
                    compact: compactTabStyle,
                    wide: wideChrome
                ) {
                    SFXManager.shared.play(.confirm)
                    selectedIndex = index
                    activateItem(index)
                }
                .frame(maxWidth: spread ? .infinity : nil)
            }
        }
    }

    private func adaptiveWordmarkPointSize(for title: String) -> CGFloat {
        let n = max(title.count, 1)
        let slack = n - 10
        guard slack > 0 else { return wordmarkSize }
        let shrink = CGFloat(slack) * (compactTabStyle ? 0.62 : 0.55)
        return max(10, wordmarkSize - shrink)
    }

    private func wordmarkTracking(for title: String) -> CGFloat {
        let n = title.count
        if n <= 12 { return 2.5 }
        if n <= 20 { return 1.4 }
        return 0.65
    }

    private func leadingWordmark(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: adaptiveWordmarkPointSize(for: title), weight: .black, design: .rounded))
            .fontDesign(.rounded)
            .fontWeight(.black)
            .tracking(wordmarkTracking(for: title))
            .foregroundStyle(theme.topBarTextColor())
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .truncationMode(.head)
            .minimumScaleFactor(0.45)
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(title == "SAKURA" || title == "Sakura" ? "Sakura" : title)
    }

    private static func wordmarkReserveWidth(barInnerWidth: CGFloat, wide: Bool = false) -> CGFloat {
        if wide {
            return sakuraClamp(barInnerWidth * 0.16, lower: 180, upper: 260)
        }
        return sakuraClamp(barInnerWidth * 0.16, lower: 70, upper: 130)
    }

    private static func sakuraClamp(_ v: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(upper, max(lower, v))
    }

    private static let dateFormat: Date.FormatStyle = .dateTime
        .weekday(.abbreviated)
        .month(.abbreviated)
        .day(.defaultDigits)

    private var batteryBadge: some View {
        let level = max(0, min(1, batterySnapshot.level))
        let known = batterySnapshot.level >= 0
        let bodyWidth: CGFloat = 26
        let bodyHeight: CGFloat = 13
        let innerWidth = max(4, (bodyWidth - 3) * CGFloat(level))
        let tint = batteryRenderedTint

        return ZStack(alignment: .trailing) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(theme.topBarTextColor().opacity(0.05))
                    .frame(width: bodyWidth, height: bodyHeight)

                if known {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint.opacity(batterySnapshot.isCharging ? 0.42 : 0.28))
                        .frame(width: innerWidth, height: bodyHeight - 3)
                        .padding(.leading, 1.5)
                }

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(tint, lineWidth: 1.3)
                    .frame(width: bodyWidth, height: bodyHeight)

                Text(known ? "\(Int((level * 100).rounded()))" : "?")
                    .font(.system(size: 7, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.topBarCaptionColor().opacity(0.96))
                    .frame(width: bodyWidth, height: bodyHeight)
            }

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(tint)
                .frame(width: 2.5, height: 5.5)
                .offset(x: 3.5)
        }
        .frame(width: bodyWidth + 6, height: bodyHeight)
        .accessibilityLabel(batteryAccessibilityLabel)
        .accessibilityElement(children: .ignore)
    }

    private var batteryRenderedTint: Color {
        if batterySnapshot.isCharging { return .green }
        guard batterySnapshot.level >= 0 else {
            return theme.topBarAccentColor().opacity(0.7)
        }
        if batterySnapshot.level < 0.15 { return .red }
        if batterySnapshot.level < 0.3 { return .yellow }
        return theme.topBarAccentColor()
    }

    private var batteryAccessibilityLabel: String {
        let pct = batterySnapshot.percentText ?? SakuraL10n.tr("library.a11y.batteryPctUnknown")
        if batterySnapshot.isCharging {
            return SakuraL10n.trf("library.a11y.batteryChargingFmt", pct)
        }
        return SakuraL10n.trf("library.a11y.batteryFmt", pct)
    }
}

// MARK: - Battery snapshot

private struct BatteryInfo {
    var level: Float
    var isCharging: Bool

    @MainActor
    static func enableMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    @MainActor
    static func current() -> BatteryInfo {
        enableMonitoring()
        let device = UIDevice.current
        let state = device.batteryState
        let charging = (state == .charging || state == .full)
        var rawLevel = device.batteryLevel

        #if targetEnvironment(simulator)
        if rawLevel < 0 { rawLevel = 1.0 }
        #endif

        return BatteryInfo(level: rawLevel, isCharging: charging)
    }

    var percentText: String? {
        guard level >= 0 else { return nil }
        let clamped = max(0, min(100, Int(round(level * 100))))
        return "\(clamped)%"
    }

}

extension LibraryShell {
    nonisolated static func mappedLibraryItems(
        fileNames: [String],
        gamesDir: String,
        docsDir: String,
        emulationIsRunning: Bool
    ) -> [GameItem] {
        let fm = FileManager.default
        var cacheAdds: [String: String] = [:]
        let items: [GameItem] = fileNames.map { name in
            var path = (gamesDir as NSString).appendingPathComponent(name)
            if !fm.fileExists(atPath: path) {
                path = (docsDir as NSString).appendingPathComponent(name)
            }

            let base = (path as NSString).deletingPathExtension
            var coverPath: String?
            if fm.fileExists(atPath: base + ".png") {
                coverPath = base + ".png"
            } else if fm.fileExists(atPath: base + ".jpg") {
                coverPath = base + ".jpg"
            }

            var resolvedSerial: String?
            var fromIdentityCache = false
            if let ik = sakuraLibraryPayloadIdentityCacheKey(for: path) {
                switch SerialCache.shared.lookup(identityCacheKey: ik) {
                case let .hit(s):
                    fromIdentityCache = true
                    resolvedSerial = s.isEmpty ? nil : s
                case .absent:
                    break
                }
            }
            if !fromIdentityCache {
                let flattened = SakuraBridge.isoSerial(forPath: path) ?? ""
                resolvedSerial = flattened.isEmpty ? nil : flattened
                if let ik = sakuraLibraryPayloadIdentityCacheKey(for: path) {
                    cacheAdds[ik] = flattened
                }
            }

            var titleSource: String?
            if let dbTitle = SakuraBridge.isoTitle(forPath: path), !dbTitle.isEmpty {
                titleSource = dbTitle
            }

            let dedKey: String = {
                if path.isEmpty { return "f:\(name)" }
                return SakuraBridge.libraryDedupKey(forCachedSerial: resolvedSerial, isoPath: path)
            }()

            if !emulationIsRunning,
               let s = resolvedSerial,
               let cached = GameMetadataService.shared.cachedCoverPath(forSerial: s) {
                coverPath = GameMetadataService.shared.cachedUpscaledCoverPath(forSerial: s) ?? cached
            }

            // Use the payload size (sum of referenced BIN/IMG for .cue/.m3u/.ccd)
            // so multi-disc playlists don't show up as a nonsense "80 bytes".
            let size = SakuraBridge.totalPayloadByteCount(forISOPath: path)
            let fav = SakuraBridge.isFavorite(name)
            let baseTitle = titleSource ?? (name as NSString).deletingPathExtension

            let metadataKey = sakuraLibraryMetadataLookupKey(fileName: name, serial: resolvedSerial)
            if coverPath == nil,
               let cachedCover = GameMetadataService.shared.cachedCoverPath(forSerial: metadataKey) {
                coverPath = GameMetadataService.shared.cachedUpscaledCoverPath(forSerial: metadataKey) ?? cachedCover
            }
            let cachedInfo = GameMetadataService.shared.cachedInfo(forSerial: metadataKey)

            return GameItem(
                fileName: name,
                title: cachedInfo?.title.isEmpty == false ? cachedInfo!.title : baseTitle,
                gameID: resolvedSerial,
                metadataKey: metadataKey,
                imagePath: coverPath,
                releaseDate: cachedInfo?.releaseDate ?? "Unknown",
                genre: cachedInfo?.genre ?? "Unknown",
                developer: cachedInfo?.developer ?? "Unknown",
                publisher: cachedInfo?.publisher ?? "Unknown",
                summary: cachedInfo?.summary ?? "",
                absolutePath: path,
                sizeBytes: size,
                isFavorite: fav,
                libraryDedupKey: dedKey
            )
        }
        if !cacheAdds.isEmpty {
            SerialCache.shared.storeBatchUnsafe(cacheAdds)
        }
        return items
    }
}

// MARK: - Library shell

struct LibraryShell: View {
    @State private var appState = AppState.shared
    @State private var gamepad = GamepadNavigation.shared
    @State private var settings = SettingsStore.shared
    @Bindable private var playtime = PlaytimeStore.shared
    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var secondaryDisplay = SecondaryDisplayCoordinator.shared
    @State private var games: [GameItem] = []
    @State private var selectedFilename: String?
    @State private var focusRegion: LibraryFocusRegion = .games
    @State private var selectedTopIndex = AppState.shared.selectedSettingsPage.rawValue + 1

    @State private var showImportPicker = false
    @State private var showMusicFirstBoot = false
    @State private var libraryAppearCount: Int = 0
    @State private var gamePendingDelete: GameItem?
    @State private var coverArtPickerISO: String?


    @State private var coverFetchTasks: [String: Bool] = [:]
    @State private var infoFetchTasks: [String: Bool] = [:]

    @State private var gameIndexByFileName: [String: Int] = [:]

    @State private var librarySaveStateRefreshToken: Int = 0

    @State private var committedLibraryFingerprint: UInt64 = 0
    @State private var libraryRefreshTicket: UInt = 0
    @State private var focusedLibrarySaveSlot: Int = 1
    @State private var gameMenuDialogGame: GameItem?

    private static let lastSelectedISODefaultsKey = "sakura.library.lastSelectedISO"
    private static let pendingLibraryLoadSlotKey = "sakura.library.pendingLoadSlot"
    private static let pendingLibraryLoadISOKey = "sakura.library.pendingLoadISO"

    private var selectedGame: GameItem? {
        guard let f = selectedFilename else { return nil }
        return games.first(where: { $0.fileName == f })
    }

    private var biosMissing: Bool {
        !SakuraBridge.hasBIOS()
    }

    private func rebuildGameIndices() {
        gameIndexByFileName = Dictionary(uniqueKeysWithValues: games.enumerated().map { ($0.element.fileName, $0.offset) })
    }

    private func dynamicTypeSize(for scale: Double) -> DynamicTypeSize {
        if scale < 0.9 { return .small }
        if scale < 1.0 { return .medium }
        if scale < 1.1 { return .large }
        if scale < 1.2 { return .xLarge }
        if scale < 1.3 { return .xxLarge }
        return .xxxLarge
    }

    private var deleteGameDialogPresented: Binding<Bool> {
        Binding(
            get: { gamePendingDelete != nil },
            set: { if !$0 { gamePendingDelete = nil } }
        )
    }

    private var coverArtImporterPresented: Binding<Bool> {
        Binding(
            get: { coverArtPickerISO != nil },
            set: { if !$0 { coverArtPickerISO = nil } }
        )
    }

    private var gameMenuDialogPresented: Binding<Bool> {
        Binding(
            get: { gameMenuDialogGame != nil },
            set: { if !$0 { gameMenuDialogGame = nil } }
        )
    }

    private var gameMenuDialogTitle: String {
        guard let g = gameMenuDialogGame else { return "" }
        let t = g.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? g.fileName : t
    }

    private func libraryResolvedGame(_ game: GameItem) -> GameItem {
        games.first(where: { $0.fileName == game.fileName }) ?? game
    }

    @ViewBuilder
    private func libraryGameCoverContextMenu(for game: GameItem) -> some View {
        let g = libraryResolvedGame(game)
        Button {
            toggleFavorite(g.fileName)
        } label: {
            Label(
                g.isFavorite ? SakuraL10n.tr("library.context.unfavorite") : SakuraL10n.tr("library.context.favorite"),
                systemImage: g.isFavorite ? "star.slash" : "star.fill"
            )
        }
        Button {
            performUpscaleCover(for: g)
        } label: {
            Label(SakuraL10n.tr("library.context.upscaleCover"), systemImage: "wand.and.stars")
        }
        Button {
            coverArtPickerISO = g.fileName
        } label: {
            Label(SakuraL10n.tr("library.context.changeCover"), systemImage: "photo.on.rectangle.angled")
        }
        Button(role: .destructive) {
            gamePendingDelete = g
        } label: {
            Label(SakuraL10n.tr("library.context.deleteGame"), systemImage: "trash")
        }
    }

    @ViewBuilder
    private func libraryGameMenuFooterLabel(compact: Bool) -> some View {
        let purple = theme.color(forKey: "purple")
        let circleSize: CGFloat = compact ? 20 : 22
        let hPad: CGFloat = compact ? 10 : 12
        let vPad: CGFloat = 6
        let glyphPt: CGFloat = compact ? 10 : 12
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(purple.opacity(0.15))
                    .frame(width: circleSize, height: circleSize)
                    .overlay(
                        Circle()
                            .stroke(purple.opacity(0.35), lineWidth: 1)
                    )
                if gamepad.hasHardwareKeyboard {
                    Text(SakuraL10n.tr("keyboard.shell.j"))
                        .font(.system(size: glyphPt, weight: .bold))
                        .foregroundColor(purple)
                } else if UIImage(systemName: "playstation.square") != nil {
                    Image(systemName: "playstation.square")
                        .font(.system(size: glyphPt, weight: .bold))
                        .foregroundColor(purple)
                } else {
                    Text("□")
                        .font(.system(size: glyphPt, weight: .bold))
                        .foregroundColor(purple)
                }
            }
            Text(SakuraL10n.tr("library.bottom.gameMenu"))
                .font(.system(size: compact ? 9 : 11, weight: .bold, design: .rounded))
                .tracking(compact ? 0.3 : 0.8)
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(compact ? 0.72 : 0.65)
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background {
            Group {
                if theme.materialsReduced {
                    Capsule().fill(Color.black.opacity(0.72))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
        }
        .clipShape(Capsule())
    }

    private var libraryStack: some View {
        ZStack(alignment: .bottom) {
            libraryStackContent
            if !settings.bottomActionBarHidden, !games.isEmpty, !biosMissing, let game = selectedGame {
                libraryFloatingActionBar(game: game, footerCompact: true)
                    .padding(.bottom, max(8, footerBottomSafeInset() - 2))
            }
        }
    }

    @ViewBuilder
    private func libraryFloatingActionBar(game: GameItem, footerCompact: Bool) -> some View {
        libraryActionBadgesHStack(game: game, libraryFooterCompact: footerCompact)
            .padding(.horizontal, 4)
    }

    private var libraryStackContent: some View {
        VStack(spacing: 0) {
                TopBar(
                    selectedIndex: $selectedTopIndex,
                    controllerFocusActive: gamepad.shellNavInputActive && focusRegion == .topBar,
                    wideChrome: false,
                    activateItem: activateTopBarSelection
                )

                Group {
                    if biosMissing && games.isEmpty {
                        firmwareRequiredEmpty
                        Spacer()
                    } else {
                        GameCoverCarousel(
                            games: games,
                            selectedFilename: $selectedFilename,
                            controllerActive: gamepad.shellNavInputActive && focusRegion == .games,
                            launchOnTap: settings.bottomActionBarHidden,
                            coverContextMenu: { g in libraryGameCoverContextMenu(for: g) },
                            onLaunch: { game in
                                playTapped(fileName: game.fileName)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.dynamicTypeSize, .medium)
                        .padding(.top, 2)
                        .onChange(of: games) { _, newGames in
                            syncSelection(after: newGames)
                        }

                        Group {
                            if biosMissing && !games.isEmpty {
                                firmwareRequiredWithGames
                            } else if let game = selectedGame {
                                bottomMetadataAndActions(game: game)
                            } else if games.isEmpty {
                                noGamesEmpty
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, footerBottomSafeInset() + (settings.bottomActionBarHidden ? 0 : 44))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .fontDesign(theme.libraryFontDesign())
                .fontWeight(theme.libraryFontWeight())
                .environment(\.dynamicTypeSize, dynamicTypeSize(for: theme.libraryTextScale))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
    }

    private var libraryAppearanceLayer: some View {
        libraryStack
            .sheet(isPresented: $showMusicFirstBoot) {
                MusicFirstBootPrompt(isPresented: $showMusicFirstBoot)
            }
            .onAppear {
                gamepad.enterLibrary()
                refreshLibrary()
                syncControllerFocus()
                syncTopBarSelection()
                libraryAppearCount &+= 1
                if gamepad.shellNavInputActive && !games.isEmpty {
                    focusRegion = .games
                }
                evaluateMusicFirstBoot()
                MusicPlayer.shared.autoResumeIfStickyAndLibraryVisible()
            }
            .onChange(of: selectedFilename) { _, newValue in
                if let newValue {
                    UserDefaults.standard.set(newValue, forKey: Self.lastSelectedISODefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.lastSelectedISODefaultsKey)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    refreshLibrary(force: true)
                }
            }
            .onChange(of: games) { _, _ in
                syncControllerFocus()
            }
            .onChange(of: appState.selectedSettingsPage) { _, _ in
                syncTopBarSelection()
            }
            .onChange(of: gamepad.isActive) { _, _ in
                syncControllerFocus()
            }
            .onChange(of: secondaryDisplay.externalRasterSurfaceAvailable) { _, available in
                syncControllerFocus()
                if available, !games.isEmpty, focusRegion != .games {
                    focusRegion = .games
                }
            }
            .onChange(of: gamepad.hasHardwareKeyboard) { _, active in
                syncControllerFocus()
                if active, !games.isEmpty, focusRegion != .games {
                    focusRegion = .games
                }
            }
            .onChange(of: gamepad.actionID) { _, _ in
                guard gamepad.context == .library else { return }
                handleGamepadAction()
            }
            .onChange(of: settings.saveStatesEnabled) { _, _ in
                refreshLibrary(force: true)
            }
            .onDisappear {
                // don't leave; next screen claims context in its onAppear
            }
    }

    var body: some View {
        libraryAppearanceLayer
            .background {
                Color.clear
                    .fileImporter(
                        isPresented: $showImportPicker,
                        allowedContentTypes: FileImporterTypes.libraryGameImports,
                        allowsMultipleSelection: true
                    ) { handleLibraryBulkImportCompletion($0) }
            }
            .background {
                Color.clear
                    .fileImporter(
                        isPresented: coverArtImporterPresented,
                        allowedContentTypes: FileImporterTypes.coverArtImports,
                        allowsMultipleSelection: false
                    ) { handleCoverArtImportCompletion($0) }
            }
            .confirmationDialog(
                SakuraL10n.tr("library.alert.delete.title"),
                isPresented: deleteGameDialogPresented,
                titleVisibility: .visible
            ) {
                Button(SakuraL10n.tr("library.alert.delete.confirm"), role: .destructive) {
                    if let game = gamePendingDelete {
                        performDeleteLibraryGame(game)
                    }
                    gamePendingDelete = nil
                }
                Button(SakuraL10n.tr("common.cancel"), role: .cancel) {
                    gamePendingDelete = nil
                }
            } message: {
                let label = gamePendingDelete?.title ?? gamePendingDelete?.fileName ?? ""
                Text(SakuraL10n.trf("library.alert.delete.message", label))
            }
            .confirmationDialog(
                gameMenuDialogTitle,
                isPresented: gameMenuDialogPresented,
                titleVisibility: .visible
            ) {
                if let g = gameMenuDialogGame {
                    let resolved = libraryResolvedGame(g)
                    Button(resolved.isFavorite
                        ? SakuraL10n.tr("library.context.unfavorite")
                        : SakuraL10n.tr("library.context.favorite")) {
                        toggleFavorite(resolved.fileName)
                        gameMenuDialogGame = nil
                    }
                    Button(SakuraL10n.tr("library.context.upscaleCover")) {
                        performUpscaleCover(for: resolved)
                        gameMenuDialogGame = nil
                    }
                    Button(SakuraL10n.tr("library.context.changeCover")) {
                        coverArtPickerISO = resolved.fileName
                        gameMenuDialogGame = nil
                    }
                    Button(SakuraL10n.tr("library.context.deleteGame"), role: .destructive) {
                        gamePendingDelete = resolved
                        gameMenuDialogGame = nil
                    }
                }
                Button(SakuraL10n.tr("common.cancel"), role: .cancel) {
                    gameMenuDialogGame = nil
                }
            }
            .onChange(of: appState.runningGameName) { oldValue, newValue in
                if oldValue != nil && newValue == nil {
                    refreshLibrary(force: true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sakuraCoverUpscaleFinished)) { note in
                guard let info = note.userInfo,
                      let serial = info[GameCoverUpscaler.notificationSerialKey] as? String,
                      let path = info[GameCoverUpscaler.notificationPathKey] as? String
                else { return }
                for idx in games.indices where games[idx].gameID == serial || games[idx].metadataKey == serial {
                    var updated = games[idx]
                    updated.imagePath = path
                    games[idx] = updated
                }
            }
    }

    private func handleLibraryBulkImportCompletion(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                FileImportHandler.shared.handleURL(url)
            }
            refreshLibrary(force: true)
        case .failure(let err):
            SakuraLogUnified("UI", "Warning", "import picker failed: \(err.localizedDescription)")
        }
    }

    private func handleCoverArtImportCompletion(_ result: Result<[URL], Error>) {
        let isoSnapshot = coverArtPickerISO
        coverArtPickerISO = nil
        guard let iso = isoSnapshot,
              let game = games.first(where: { $0.fileName == iso })
        else { return }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            applyImportedCoverArt(from: url, for: game)
        case .failure(let err):
            SakuraLogUnified("UI", "Warning", "cover art picker failed: \(err.localizedDescription)")
        }
    }

    private var firmwareRequiredEmpty: some View {
        VStack(spacing: 24) {
            Image(systemName: "cpu")
                .font(.system(size: 64))
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
            Text(SakuraL10n.tr("library.fw.title"))
                .font(.title2.bold())
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
            Text(SakuraL10n.tr("library.fw.beforeGames"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var firmwareRequiredWithGames: some View {
        VStack(spacing: 24) {
            Image(systemName: "cpu")
                .font(.system(size: 64))
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
            Text(SakuraL10n.tr("library.fw.title"))
                .font(.title2.bold())
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
            Text(SakuraL10n.tr("library.fw.withGames"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
        }
        .padding(.bottom, 20)
    }

    private var noGamesEmpty: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 48))
                .foregroundStyle(theme.glassTextTertiary(colorScheme).opacity(0.7))
            Text(SakuraL10n.tr("library.empty.noGames"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.glassTextSecondary(colorScheme))
            Button {
                showImportPicker = true
            } label: {
                Label(SakuraL10n.tr("library.importGames"), systemImage: "plus.rectangle.on.folder.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(theme.glassTextPrimary(colorScheme).opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            Text(SakuraL10n.tr("library.empty.formatsHint"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 20)
    }


    private func librarySaveSlotPreview(for isoFileName: String, slot: Int) -> UIImage? {
        guard let path = SakuraBridge.saveStatePreviewPath(forISOName: isoFileName, slot: Int32(slot)),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return UIImage(contentsOfFile: path)
    }

    private func librarySaveStateSlotsRow(game: GameItem) -> some View {
        let _ = librarySaveStateRefreshToken
        let accent = theme.accentColor()
        let secondary = theme.glassTextSecondary(colorScheme)
        let chip: CGFloat = 34
        let slotFocused =
            gamepad.shellNavInputActive && focusRegion == .saveSlots && selectedFilename == game.fileName
        return HStack(spacing: 4) {
            ForEach(1...10, id: \.self) { slot in
                let exists = SakuraBridge.hasSaveState(inSlot: Int32(slot), forISOFileName: game.fileName)
                let isPadFocus = slotFocused && focusedLibrarySaveSlot == slot
                let thumb = exists ? librarySaveSlotPreview(for: game.fileName, slot: slot) : nil
                Button {
                    librarySaveSlotTapped(isoFileName: game.fileName, slot: slot, hasSave: exists)
                } label: {
                    ZStack {
                        if let thumb {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: chip, height: chip)
                                .clipped()
                                .overlay(alignment: .bottomTrailing) {
                                    Text("\(slot)")
                                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(.white.opacity(0.95))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.black.opacity(0.5)))
                                        .padding(3)
                                }
                        } else {
                            Text("\(slot)")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(exists ? .white : secondary.opacity(0.45))
                                .frame(width: chip, height: chip)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(exists ? accent.opacity(0.7) : Color.clear)
                                )
                        }

                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                exists ? accent.opacity(0.85) : secondary.opacity(0.3),
                                lineWidth: exists ? 1.2 : 1
                            )
                            .allowsHitTesting(false)
                    }
                    .frame(width: chip, height: chip)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .sakuraFocusRing(
                        isFocused: isPadFocus,
                        controllerActive: true,
                        cornerRadius: 6
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    SakuraL10n.trf(
                        "library.a11y.saveSlot.fmt",
                        "\(slot)",
                        exists ? SakuraL10n.tr("library.a11y.saveSlot.tailHasSave") : SakuraL10n.tr("library.a11y.saveSlot.tailEmpty")
                    )
                )
            }
        }
    }

    private func bottomMetadataAndActions(game: GameItem) -> some View {
        let _ = playtime.version
        let total = playtime.totalPlaytime(for: game.fileName)
        let last = playtime.lastPlayed(for: game.fileName)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                editableMetaField(
                    game: game,
                    field: .title,
                    label: "",
                    value: game.title,
                    valueFont: .system(size: 17, weight: .bold, design: .rounded),
                    width: nil,
                    lineLimit: 1,
                    translateValue: false,
                    truncateDisplayStart: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                if settings.saveStatesEnabled {
                    librarySaveStateSlotsRow(game: game)
                }
            }

            TranslatedGameMetadataLine(
                englishRaw:
                    (game.summary.isEmpty || game.summary.caseInsensitiveCompare("unknown") == .orderedSame)
                    ? "" : game.summary,
                font: .system(size: 11, weight: .regular, design: .rounded),
                lineLimit: 3,
                minimumScale: 0.92,
                reservesSpace: false
            )
            .foregroundStyle(theme.glassTextSecondary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)

            libraryMetaScrollingStrip(game: game, total: total, last: last)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, gamepad.shellNavInputActive ? 6 : 8)
    }

    @MainActor
    private func footerBottomSafeInset() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes
        let scene =
            scenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? scenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return 0 }
        let win = scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
        return win.map { $0.safeAreaInsets.bottom } ?? 0
    }

    private func libraryMetaScrollingStrip(game: GameItem, total: TimeInterval, last: Date?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                editableMetaField(
                    game: game,
                    field: .releaseDate,
                    label: SakuraL10n.tr("library.metadata.released"),
                    value: sakuraStripWikiArtifacts(game.releaseDate),
                    width: 76,
                    footerCompact: true
                )
                if total >= 1 {
                    staticMetaField(
                        label: SakuraL10n.tr("library.metadata.playtime"),
                        value: PlaytimeStore.formatDuration(total),
                        width: 76
                    )
                }
                if let last {
                    staticMetaField(
                        label: SakuraL10n.tr("library.metadata.lastPlayed"),
                        value: PlaytimeStore.formatLastPlayed(last),
                        width: 88
                    )
                }
                staticMetaField(
                    label: SakuraL10n.tr("library.metadata.size"),
                    value: PlaytimeStore.formatByteCount(game.sizeBytes),
                    width: 72
                )
                editableMetaField(
                    game: game,
                    field: .genre,
                    label: SakuraL10n.tr("library.metadata.genre"),
                    value: sakuraStripWikiArtifacts(game.genre),
                    width: 108,
                    footerCompact: true
                )
                editableMetaField(
                    game: game,
                    field: .developer,
                    label: SakuraL10n.tr("library.metadata.developer"),
                    value: sakuraStripWikiArtifacts(game.developer),
                    width: 118,
                    footerCompact: true
                )
                editableMetaField(
                    game: game,
                    field: .publisher,
                    label: SakuraL10n.tr("library.metadata.publisher"),
                    value: sakuraStripWikiArtifacts(game.publisher),
                    width: 118,
                    footerCompact: true
                )
            }
            .padding(.vertical, 2)
        }
        .opacity(0.92)
    }

    @ViewBuilder
    private func libraryActionBadgesHStack(game: GameItem, libraryFooterCompact: Bool) -> some View {
        let kb = gamepad.hasHardwareKeyboard
        HStack(alignment: .center, spacing: 6) {
            PSActionBadge(
                systemName: "l1.button.roundedbottom.horizontal",
                psIcon: nil,
                psFallback: nil,
                circleGlyphText: kb ? SakuraL10n.tr("keyboard.shell.brackets") : nil,
                shoulderSymbol: kb ? nil : "l1.button.roundedbottom.horizontal",
                shoulderSymbolSecond: kb ? nil : "r1.button.roundedbottom.horizontal",
                title: SakuraL10n.tr("library.hint.pages"),
                tint: theme.color(forKey: "yellow"),
                libraryFooterCompact: libraryFooterCompact
            )

            PSActionBadge(
                systemName: "play.fill",
                psIcon: kb ? nil : "cross",
                psFallback: kb ? SakuraL10n.tr("keyboard.shell.enter") : "✕",
                title: SakuraL10n.tr("library.bottom.playCaps"),
                tint: theme.color(forKey: "blue"),
                libraryFooterCompact: libraryFooterCompact
            ) {
                playTapped(fileName: game.fileName)
            }

            PSActionBadge(
                systemName: "heart.fill",
                psIcon: kb ? nil : "circle",
                psFallback: kb ? SakuraL10n.tr("keyboard.shell.esc") : "○",
                title: SakuraL10n.tr("library.bottom.favorite"),
                tint: theme.color(forKey: "red"),
                libraryFooterCompact: libraryFooterCompact
            ) {
                toggleFavorite(game.fileName)
            }

            PSActionBadge(
                systemName: settings.fastBoot ? "bolt.fill" : "bolt.slash",
                psIcon: kb ? nil : "triangle",
                psFallback: kb ? SakuraL10n.tr("keyboard.shell.l") : "△",
                title: settings.fastBoot ? SakuraL10n.tr("library.bottom.fastBoot") : SakuraL10n.tr("library.bottom.fullBoot"),
                tint: theme.color(forKey: "green"),
                libraryFooterCompact: libraryFooterCompact
            ) {
                settings.fastBoot.toggle()
            }

            Menu {
                libraryGameCoverContextMenu(for: game)
            } label: {
                libraryGameMenuFooterLabel(compact: libraryFooterCompact)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .layoutPriority(0)

            PSActionBadge(
                systemName: "line.3.horizontal",
                psIcon: nil,
                psFallback: nil,
                circleGlyphText: kb ? SakuraL10n.tr("keyboard.shell.m") : nil,
                title: SakuraL10n.tr("library.bottom.import"),
                tint: theme.glassTextPrimary(.dark),
                libraryFooterCompact: libraryFooterCompact
            ) {
                showImportPicker = true
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var fastBootChip: some View {
        Button {
            settings.fastBoot.toggle()
        } label: {
            Label(
                settings.fastBoot ? SakuraL10n.tr("library.bottom.fastBoot") : SakuraL10n.tr("library.bottom.fullBoot"),
                systemImage: settings.fastBoot ? "bolt.fill" : "bolt.slash"
            )
            .font(.caption.weight(.bold))
            .foregroundStyle(theme.glassTextPrimary(colorScheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(
                    settings.fastBoot
                        ? theme.color(forKey: "yellow").opacity(0.22)
                        : theme.glassTextPrimary(colorScheme).opacity(0.12)
                )
            )
            .overlay(
                Capsule().stroke(
                    settings.fastBoot
                        ? theme.color(forKey: "yellow").opacity(0.6)
                        : theme.glassTextPrimary(colorScheme).opacity(0.18),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func staticMetaField(
        label: String,
        value: String,
        width: CGFloat?
    ) -> some View {
        let stack = VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
                .lineLimit(1)
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
                .lineLimit(1)
                .truncationMode(.head)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        if let w = width {
            stack.frame(width: w, alignment: .topLeading)
        } else {
            stack.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func editableMetaField(
        game: GameItem,
        field: GameMetadataService.EditableField,
        label: String,
        value: String,
        valueFont: Font = .footnote.weight(.semibold),
        width: CGFloat? = 65,
        lineLimit: Int? = 1,
        translateValue: Bool = true,
        footerCompact: Bool = false,
        truncateDisplayStart: Bool = true
    ) -> some View {
        EditableMetaFieldView(
            game: game,
            field: field,
            label: label,
            value: value,
            valueFont: valueFont,
            width: width,
            lineLimit: lineLimit,
            footerCompact: footerCompact,
            translateDisplay: translateValue,
            truncateDisplayStart: truncateDisplayStart,
            onCommit: { _ in refreshLibrary(force: true) }
        )
    }

    private func librarySaveSlotTapped(isoFileName: String, slot: Int, hasSave: Bool) {
        guard settings.saveStatesEnabled else { return }
        let d = UserDefaults.standard
        if hasSave {
            d.set(slot, forKey: Self.pendingLibraryLoadSlotKey)
            d.set(isoFileName, forKey: Self.pendingLibraryLoadISOKey)
            playTapped(fileName: isoFileName)
        } else {
            d.removeObject(forKey: Self.pendingLibraryLoadSlotKey)
            d.removeObject(forKey: Self.pendingLibraryLoadISOKey)
            playTapped(fileName: isoFileName, forceColdBoot: true)
        }
    }

    private func playTapped(fileName: String, forceColdBoot: Bool = false) {
        let d = UserDefaults.standard
        if let mPath = d.string(forKey: PendingMediaAttachedSaveKeys.pathDefaultsKey),
           let mIso = d.string(forKey: PendingMediaAttachedSaveKeys.expectedISODefaultsKey),
           !mPath.isEmpty,
           !mIso.isEmpty,
           !PendingMediaAttachedSaveKeys.isoMatchesStoredBoot(launchingOrBootINI: fileName, storedBootPathOrISOFromSidecar: mIso) {
            d.removeObject(forKey: PendingMediaAttachedSaveKeys.pathDefaultsKey)
            d.removeObject(forKey: PendingMediaAttachedSaveKeys.expectedISODefaultsKey)
        }
        if !settings.saveStatesEnabled || forceColdBoot {
            d.removeObject(forKey: Self.pendingLibraryLoadSlotKey)
            d.removeObject(forKey: Self.pendingLibraryLoadISOKey)
            appState.playGame(isoName: fileName)
            return
        }
        let pendingISO = d.string(forKey: Self.pendingLibraryLoadISOKey)
        let pendingSlot = d.integer(forKey: Self.pendingLibraryLoadSlotKey)
        let chipLocked = (pendingISO == fileName) && (pendingSlot >= 1 && pendingSlot <= 10)
        if !chipLocked {
            d.removeObject(forKey: Self.pendingLibraryLoadSlotKey)
            d.removeObject(forKey: Self.pendingLibraryLoadISOKey)
        }
        appState.playGame(isoName: fileName)
    }

    private func toggleFavorite(_ name: String) {
        let current = SakuraBridge.isFavorite(name)
        SakuraBridge.setFavorite(name, favorite: !current)
        refreshLibrary(force: true)
    }

    private func libraryCachedCoverOriginalPath(for game: GameItem) -> String? {
        var keys: [String] = [game.metadataKey]
        if let s = game.gameID, !s.isEmpty { keys.append(s) }
        let unique = Array(Set(keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        let fm = FileManager.default
        let covers = GameMetadataService.shared.coversDir
        for k in unique {
            for ext in ["jpg", "jpeg", "png", "webp"] {
                let url = covers.appendingPathComponent("\(k).\(ext)")
                if fm.fileExists(atPath: url.path) { return url.path }
            }
        }
        return nil
    }

    private func performUpscaleCover(for game: GameItem) {
        guard let path = libraryCachedCoverOriginalPath(for: game) else { return }
        let trimmedID = game.gameID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let serialTag = trimmedID.isEmpty ? game.metadataKey : trimmedID
        GameCoverUpscaler.shared.upscaleIfNeeded(originalCoverPath: path, serial: serialTag)
    }

    private func applyImportedCoverArt(from url: URL, for game: GameItem) {
        let key = game.metadataKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let covers = GameMetadataService.shared.coversDir
        let fm = FileManager.default
        if let old = game.imagePath {
            CoverAspect.invalidate(path: old)
        }
        for ext in ["jpg", "jpeg", "png", "webp"] {
            try? fm.removeItem(at: covers.appendingPathComponent("\(key).\(ext)"))
        }
        try? fm.removeItem(at: covers.appendingPathComponent("\(key).up.png"))
        let dest = covers.appendingPathComponent("\(key).png")
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try data.write(to: dest, options: .atomic)
        } catch {
            SakuraLogUnified("Library", "Warning", "custom cover write failed: \(error.localizedDescription)")
            return
        }
        CoverAspect.invalidate(path: dest.path)
        refreshLibrary(force: true)
    }

    private func removeAdjacentGameCoverArtFiles(gamePath: String) {
        let base = (gamePath as NSString).deletingPathExtension
        let fm = FileManager.default
        for ext in ["png", "jpg", "jpeg"] {
            let p = base + "." + ext
            guard fm.fileExists(atPath: p) else { continue }
            CoverAspect.invalidate(path: p)
            try? fm.removeItem(atPath: p)
        }
    }

    private func performDeleteLibraryGame(_ game: GameItem) {
        if appState.runningGameName == game.fileName {
            SakuraLogUnified("Library", "Warning", "delete game skipped: title is running")
            return
        }
        guard let path = game.absolutePath ?? SakuraBridge.resolvedAbsolutePath(forLibraryISO: game.fileName),
              FileManager.default.fileExists(atPath: path)
        else {
            SakuraLogUnified("Library", "Warning", "delete game: missing path for \(game.fileName)")
            return
        }
        if let img = game.imagePath {
            CoverAspect.invalidate(path: img)
        }
        removeAdjacentGameCoverArtFiles(gamePath: path)
        SakuraBridge.deleteSaveStatesAndPreviews(forLibraryISO: game.fileName)
        GameMetadataService.shared.removeCachedSidecarsForLibraryListing(metadataKey: game.metadataKey, discSerial: game.gameID)
        let fm = FileManager.default
        do {
            try fm.removeItem(atPath: path)
        } catch {
            SakuraLogUnified("Library", "Warning", "delete game failed: \(error.localizedDescription)")
            return
        }
        SakuraBridge.setFavorite(game.fileName, favorite: false)
        PlaytimeStore.shared.removePlaytimeRecords(for: game.fileName)
        let d = UserDefaults.standard
        if d.string(forKey: Self.pendingLibraryLoadISOKey) == game.fileName {
            d.removeObject(forKey: Self.pendingLibraryLoadISOKey)
            d.removeObject(forKey: Self.pendingLibraryLoadSlotKey)
        }
        if d.string(forKey: Self.lastSelectedISODefaultsKey) == game.fileName {
            d.removeObject(forKey: Self.lastSelectedISODefaultsKey)
        }
        selectedFilename = nil
        refreshLibrary(force: true)
    }

    private func syncSelection(after newGames: [GameItem]) {
        if let f = selectedFilename, newGames.contains(where: { $0.fileName == f }) {
            syncControllerFocus()
            return
        }
        if let stored = UserDefaults.standard.string(forKey: Self.lastSelectedISODefaultsKey),
           newGames.contains(where: { $0.fileName == stored }) {
            selectedFilename = stored
            syncControllerFocus()
            return
        }
        selectedFilename = newGames.first?.fileName
        syncControllerFocus()
    }

    private func syncControllerFocus() {
        if games.isEmpty {
            focusRegion = .topBar
        } else if !gamepad.shellNavInputActive {
            focusRegion = .games
        } else if selectedFilename == nil {
            selectedFilename = games.first?.fileName
            focusRegion = .games
        }
    }

    private func syncTopBarSelection() {
        selectedTopIndex = 0
    }

    private func evaluateMusicFirstBoot() {
        let defaults = UserDefaults.standard
        guard libraryAppearCount >= 2 else { return }
        guard !defaults.bool(forKey: "sakura.music.firstBoot.done") else { return }
        guard !defaults.bool(forKey: "sakura.music.firstBoot.skipped") else { return }
        if MusicPlayer.shared.playlist.isEmpty {
            showMusicFirstBoot = true
        }
    }

    private func handleGamepadAction() {
        guard appState.currentScreen == .menu else { return }
        if gamepad.context != .library { gamepad.enterLibrary() }
        guard let action = gamepad.lastAction else { return }
        if gameMenuDialogGame != nil {
            if action == .back {
                SFXManager.shared.play(.back)
                gameMenuDialogGame = nil
            }
            return
        }
        if gamePendingDelete != nil {
            if action == .back {
                SFXManager.shared.play(.back)
                gamePendingDelete = nil
            }
            return
        }
        switch action {
        case .moveLeft:
            if focusRegion == .topBar {
                let count = SettingsPage.allCases.count + 2
                let next = (selectedTopIndex - 1 + count) % count
                if next != selectedTopIndex {
                    selectedTopIndex = next
                    SFXManager.shared.play(.navigate)
                }
            } else if focusRegion == .saveSlots {
                focusedLibrarySaveSlot = focusedLibrarySaveSlot <= 1 ? 10 : (focusedLibrarySaveSlot - 1)
                SFXManager.shared.play(.navigate)
            } else {
                moveGameSelection(delta: -1)
            }
        case .moveRight:
            if focusRegion == .topBar {
                let count = SettingsPage.allCases.count + 2
                let next = (selectedTopIndex + 1) % count
                if next != selectedTopIndex {
                    selectedTopIndex = next
                    SFXManager.shared.play(.navigate)
                }
            } else if focusRegion == .saveSlots {
                focusedLibrarySaveSlot = focusedLibrarySaveSlot >= 10 ? 1 : (focusedLibrarySaveSlot + 1)
                SFXManager.shared.play(.navigate)
            } else {
                moveGameSelection(delta: 1)
            }
        case .moveUp:
            if focusRegion == .games {
                focusRegion = .topBar
                SFXManager.shared.play(.navigate)
            } else if focusRegion == .saveSlots {
                focusRegion = .games
                SFXManager.shared.play(.navigate)
            }
        case .moveDown:
            if focusRegion == .topBar && !games.isEmpty {
                focusRegion = .games
                SFXManager.shared.play(.navigate)
            } else if focusRegion == .games,
                      settings.saveStatesEnabled,
                      selectedGame != nil {
                focusRegion = .saveSlots
                focusedLibrarySaveSlot = min(max(focusedLibrarySaveSlot, 1), 10)
                SFXManager.shared.play(.navigate)
            }
        case .confirm:
            SFXManager.shared.play(.confirm)
            if focusRegion == .topBar {
                activateTopBarSelection()
            } else if focusRegion == .saveSlots,
                      let game = selectedGame {
                let slot = focusedLibrarySaveSlot
                let exists = SakuraBridge.hasSaveState(
                    inSlot: Int32(slot),
                    forISOFileName: game.fileName
                )
                librarySaveSlotTapped(isoFileName: game.fileName, slot: slot, hasSave: exists)
            } else {
                activateSelectedGame()
            }
        case .secondary:
            if focusRegion == .games, let g = selectedGame {
                SFXManager.shared.play(.toggle)
                gameMenuDialogGame = libraryResolvedGame(g)
            }
        case .tertiary:
            SFXManager.shared.play(.toggle)
            settings.fastBoot.toggle()
        case .menu:
            SFXManager.shared.play(.confirm)
            showImportPicker = true
        case .shoulderLeft:
            SFXManager.shared.play(.navigate)
            appState.cycleTopSection(delta: -1)
        case .shoulderRight:
            SFXManager.shared.play(.navigate)
            appState.cycleTopSection(delta: 1)
        case .triggerLeft:
            break
        case .triggerRight:
            break
        case .captureCancel:
            break
        case .back:
            if focusRegion == .saveSlots {
                focusRegion = .games
                SFXManager.shared.play(.back)
            } else if focusRegion == .games, let selectedFilename {
                SFXManager.shared.play(.toggle)
                toggleFavorite(selectedFilename)
            } else if focusRegion == .topBar {
                SFXManager.shared.play(.back)
            }
        }
    }

    private func moveGameSelection(delta: Int) {
        guard !games.isEmpty else { return }
        guard let selectedFilename,
              let currentIndex = gameIndexByFileName[selectedFilename] else {
            self.selectedFilename = games.first?.fileName
            SFXManager.shared.play(.navigate)
            return
        }

        let nextIndex = max(0, min(games.count - 1, currentIndex + delta))
        if games[nextIndex].fileName != selectedFilename {
            self.selectedFilename = games[nextIndex].fileName
            SFXManager.shared.play(.navigate)
        }
    }

    private func activateTopBarSelection() {
        activateTopBarSelection(selectedTopIndex)
    }

    private func activateTopBarSelection(_ index: Int) {
        switch index {
        case 0:
            break
        case 1:
            appState.openMedia()
        default:
            let settingsIndex = min(max(index - 2, 0), SettingsPage.allCases.count - 1)
            appState.openSettings(page: SettingsPage.allCases[settingsIndex])
        }
    }

    private func activateSelectedGame() {
        guard let game = selectedGame else { return }
        playTapped(fileName: game.fileName)
    }

    private func refreshLibrary(force: Bool = false) {
        let gamesDir = SakuraBridge.isoDirectory()
        let docsDir = SakuraBridge.documentsDirectory()
        let fileNames = SakuraBridge.availableISOs()
        let emulationIsRunning = SakuraBridge.isEmulationRunning()
        let mapFp = sakuraISOListingFingerprint(names: fileNames, emulationStoppedForMapping: !emulationIsRunning)
        if !force, !games.isEmpty, mapFp == committedLibraryFingerprint {
            return
        }
        libraryRefreshTicket &+= 1
        let ticket = libraryRefreshTicket
        Task {
            let mappedRaw = await Task.detached(priority: .utility) {
                LibraryShell.mappedLibraryItems(
                    fileNames: fileNames,
                    gamesDir: gamesDir,
                    docsDir: docsDir,
                    emulationIsRunning: emulationIsRunning
                )
            }.value
            await MainActor.run {
                guard ticket == libraryRefreshTicket else { return }
                committedLibraryFingerprint = mapFp
                games = sakuraDeduplicatedLibraryGames(mappedRaw).sorted { a, b in
                    if a.isFavorite != b.isFavorite { return a.isFavorite }
                    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
                rebuildGameIndices()
                syncSelection(after: games)

                if !emulationIsRunning {
                    for game in games {
                        if let serial = game.gameID, game.imagePath == nil, coverFetchTasks[serial] != true {
                            coverFetchTasks[serial] = true
                            GameMetadataService.shared.fetchCover(forSerial: serial) { fetchedPath in
                                DispatchQueue.main.async {
                                    if let fetchedPath = fetchedPath,
                                       let idx = self.gameIndexByFileName[game.fileName] {
                                        var updated = self.games[idx]
                                        updated.imagePath = GameMetadataService.shared.cachedUpscaledCoverPath(forSerial: serial) ?? fetchedPath
                                        self.games[idx] = updated
                                    }
                                    self.coverFetchTasks.removeValue(forKey: serial)
                                }
                            }
                        } else if game.gameID == nil, game.imagePath == nil, coverFetchTasks[game.metadataKey] != true {
                            coverFetchTasks[game.metadataKey] = true
                            GameMetadataService.shared.fetchCover(forCacheKey: game.metadataKey, title: game.title) { fetchedPath in
                                DispatchQueue.main.async {
                                    if let fetchedPath = fetchedPath,
                                       let idx = self.gameIndexByFileName[game.fileName] {
                                        var updated = self.games[idx]
                                        updated.imagePath = GameMetadataService.shared.cachedUpscaledCoverPath(forSerial: game.metadataKey) ?? fetchedPath
                                        self.games[idx] = updated
                                    }
                                    self.coverFetchTasks.removeValue(forKey: game.metadataKey)
                                }
                            }
                        }

                        let needsInfo = (game.releaseDate == "Unknown" && game.genre == "Unknown"
                            && game.developer == "Unknown" && game.publisher == "Unknown")
                        if needsInfo, infoFetchTasks[game.metadataKey] != true {
                            infoFetchTasks[game.metadataKey] = true
                            GameMetadataService.shared.fetchInfo(forSerial: game.metadataKey, title: game.title) { info in
                                DispatchQueue.main.async {
                                    if let info,
                                       let idx = self.gameIndexByFileName[game.fileName] {
                                        var updated = self.games[idx]
                                        if !info.title.isEmpty { updated.title = info.title }
                                        updated.releaseDate = info.releaseDate
                                        updated.genre = info.genre
                                        updated.developer = info.developer
                                        updated.publisher = info.publisher
                                        updated.summary = info.summary
                                        self.games[idx] = updated
                                    }
                                    self.infoFetchTasks.removeValue(forKey: game.metadataKey)
                                }
                            }
                        }
                    }
                }
                librarySaveStateRefreshToken &+= 1
            }
        }
    }

}

// MARK: - Editable metadata field

private struct EditableMetaFieldView: View {
    let game: GameItem
    let field: GameMetadataService.EditableField
    let label: String
    let value: String
    var valueFont: Font = .footnote.weight(.semibold)
    var width: CGFloat? = 65
    var lineLimit: Int? = 1
    var footerCompact: Bool = false
    var translateDisplay: Bool = true
    var truncateDisplayStart: Bool = true

    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool

    private var metaColumnValueFont: Font {
        .system(size: footerCompact ? 9 : 11, weight: .semibold, design: .rounded)
    }

    private var displayFont: Font {
        label.isEmpty ? valueFont : metaColumnValueFont
    }

    private var valueTruncation: Text.TruncationMode {
        truncateDisplayStart ? .head : .tail
    }

    private var metaColumnBody: some View {
        VStack(alignment: .leading, spacing: label.isEmpty ? 0 : 1) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: footerCompact ? 8 : 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
                    .lineLimit(1)
            }

            if editing {
                TextField("", text: $draft)
                    .font(displayFont)
                    .foregroundStyle(.primary)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
            } else {
                Group {
                    if translateDisplay {
                        TranslatedGameMetadataLine(
                            englishRaw: value,
                            font: displayFont,
                            lineLimit: lineLimit,
                            minimumScale: label.isEmpty ? 0.55 : 1.0,
                            truncationMode: valueTruncation
                        )
                    } else if let lim = lineLimit {
                        Text(value)
                            .font(displayFont)
                            .lineLimit(lim)
                            .truncationMode(valueTruncation)
                            .minimumScaleFactor(label.isEmpty ? 0.55 : 1.0)
                            .multilineTextAlignment(truncateDisplayStart ? .trailing : .leading)
                            .frame(maxWidth: .infinity, alignment: truncateDisplayStart ? .trailing : .leading)
                    } else {
                        Text(value)
                            .font(displayFont)
                            .minimumScaleFactor(label.isEmpty ? 0.55 : 1.0)
                            .truncationMode(valueTruncation)
                            .multilineTextAlignment(truncateDisplayStart ? .trailing : .leading)
                            .frame(maxWidth: .infinity, alignment: truncateDisplayStart ? .trailing : .leading)
                    }
                }
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
                .contentShape(Rectangle())
                .onTapGesture {
                    draft = (value == "Unknown") ? "" : value
                    editing = true
                    DispatchQueue.main.async { focused = true }
                }
            }
        }
    }

    var body: some View {
        Group {
            if let w = width {
                metaColumnBody.frame(width: w, alignment: .topLeading)
            } else {
                metaColumnBody.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        focused = false
        GameMetadataService.shared.updateField(field, to: draft, forSerial: game.metadataKey)
        onCommit(draft)
    }
}
