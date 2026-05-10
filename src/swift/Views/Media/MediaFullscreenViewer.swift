// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import AVFoundation
import UIKit
import Combine

struct MediaFullscreenViewer: View {
    @ObservedObject var store: MediaLibraryStore
    let initialItem: MediaItem
    let onLoadState: (MediaItem, String) -> Void
    let onSetBackground: (MediaItem) -> Void
    let onDelete: (MediaItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0
    @State private var gamepad = GamepadNavigation.shared
    @State private var pageableItems: [MediaItem] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if pageableItems.isEmpty {
                ProgressView()
                    .tint(.white)
            } else {
                TabView(selection: $index) {
                    ForEach(Array(pageableItems.enumerated()), id: \.element.id) { idx, item in
                        Group {
                            if item.isVideo {
                                MediaVideoPlayerView(
                                    item: item,
                                    isActive: idx == index,
                                    onLoadState: { leaf in onLoadState(item, leaf) },
                                    onSetBackground: { onSetBackground(item) },
                                    onDelete: { onDelete(item) },
                                    onClose: { dismiss() },
                                    onPagePrev: { stepIndex(-1) },
                                    onPageNext: { stepIndex(1) }
                                )
                            } else {
                                MediaImagePage(
                                    item: item,
                                    onLoadState: { leaf in onLoadState(item, leaf) },
                                    onSetBackground: { onSetBackground(item) },
                                    onDelete: { onDelete(item) },
                                    onClose: { dismiss() },
                                    onPagePrev: { stepIndex(-1) },
                                    onPageNext: { stepIndex(1) }
                                )
                            }
                        }
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
        }
        .onAppear {
            preparePageable()
            gamepad.enterMediaViewer()
        }
        .onDisappear {
            gamepad.enterLibrary()
        }
    }

    private func preparePageable() {
        pageableItems = store.items.filter { $0.kind == initialItem.kind }
        index = pageableItems.firstIndex(where: { $0.id == initialItem.id }) ?? 0
    }

    private func stepIndex(_ delta: Int) {
        guard !pageableItems.isEmpty else { return }
        let n = pageableItems.count
        index = ((index + delta) % n + n) % n
    }
}

// MARK: - Image page

private struct MediaImagePage: View {
    let item: MediaItem
    let onLoadState: (String) -> Void
    let onSetBackground: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    let onPagePrev: () -> Void
    let onPageNext: () -> Void

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showOverlay = true
    @State private var hideTask: Task<Void, Never>?
    @State private var gamepad = GamepadNavigation.shared
    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(scale)
                            .offset(offset)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { v in scale = max(1.0, min(5.0, lastScale * v)) }
                                    .onEnded { _ in lastScale = scale; if scale <= 1.001 { offset = .zero; lastOffset = .zero } }
                            )
                            .simultaneousGesture(
                                DragGesture()
                                    .onChanged { v in
                                        guard scale > 1.01 else { return }
                                        offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                                    }
                                    .onEnded { _ in lastOffset = offset }
                            )
                            .onTapGesture(count: 2) {
                                if scale > 1.01 {
                                    scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero
                                } else {
                                    scale = 2.0; lastScale = 2.0
                                }
                            }
                            .onTapGesture { toggleOverlay() }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
            }
            .ignoresSafeArea()

            if showOverlay {
                MediaPlayerOverlay(
                    item: item,
                    isVideo: false,
                    onLoadState: onLoadState,
                    onSetBackground: onSetBackground,
                    onDelete: onDelete,
                    onClose: onClose
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if gamepad.shellNavInputActive && showOverlay {
                MediaHintRow(items: imageHintItems())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onChange(of: gamepad.actionID) { _, _ in
            handleAction()
        }
        .task {
            await loadImage()
            scheduleAutoHide()
        }
    }

    private func imageHintItems() -> [MediaHintRow.Chip] {
        var items: [MediaHintRow.Chip] = []
        items.append(.shoulder("L1/R1", title: SakuraL10n.tr("media.controllerHint.prevNext")))
        items.append(.face(.confirm, title: SakuraL10n.tr("media.controllerHint.zoomOrPause")))
        items.append(.face(.back, title: SakuraL10n.tr("media.player.close")))
        items.append(.face(.secondary, title: SakuraL10n.tr("media.viewer.setBackground")))
        if item.sidecar?.savedStateAtStart != nil || item.sidecar?.savedStateAtEnd != nil {
            items.append(.face(.tertiary, title: SakuraL10n.tr("media.viewer.loadSaveState")))
        }
        return items
    }

    private func toggleOverlay() {
        withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) { showOverlay = false }
            }
        }
    }

    private func showOverlayBriefly() {
        withAnimation(.easeInOut(duration: 0.15)) { showOverlay = true }
        scheduleAutoHide()
    }

    private func handleAction() {
        guard let action = gamepad.lastAction else { return }
        switch action {
        case .back:
            SFXManager.shared.play(.back)
            onClose()
        case .confirm:
            if scale > 1.01 {
                scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero
            } else {
                scale = 2.0; lastScale = 2.0
            }
            showOverlayBriefly()
        case .secondary:
            onSetBackground()
            showOverlayBriefly()
        case .tertiary:
            if let s = item.sidecar?.savedStateAtStart { onLoadState(s) }
            else if let e = item.sidecar?.savedStateAtEnd { onLoadState(e) }
            showOverlayBriefly()
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            showOverlayBriefly()
        case .shoulderLeft:
            onPagePrev()
            showOverlayBriefly()
        case .shoulderRight:
            onPageNext()
            showOverlayBriefly()
        case .triggerLeft, .triggerRight:
            break
        default:
            break
        }
    }

    private func loadImage() async {
        let url = item.url
        let img: UIImage? = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: url.path)
        }.value
        image = img
    }
}

// MARK: - Custom controller-native video player

@MainActor
final class MediaVideoController: ObservableObject {
    nonisolated(unsafe) let player: AVPlayer
    nonisolated(unsafe) let asset: AVURLAsset
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var statusObserver: NSKeyValueObservation?

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 1.0
    @Published var rate: Float = 1.0

    init(url: URL) {
        self.asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: item)
        player.volume = volume
        player.actionAtItemEnd = .pause

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.status == .readyToPlay {
                    let secs = item.duration.seconds
                    if secs.isFinite, secs > 0 { self.duration = secs }
                }
            }
        }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = t.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0, self.duration != d {
                    self.duration = d
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObserver?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func itemDidEnd(_ note: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.player.seek(to: .zero)
        }
    }

    func play() {
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func seekBy(_ delta: Double) {
        let target = max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude, currentTime + delta))
        let cm = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    func seekTo(_ t: Double) {
        let target = max(0, min(duration > 0 ? duration : t, t))
        let cm = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    func setVolume(_ v: Float) {
        let clamped = max(0, min(1, v))
        volume = clamped
        player.volume = clamped
    }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player.rate = r }
    }
}

private struct MediaPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private enum VideoFocusSlot: Int, CaseIterable {
    case scrub
    case speed
    case volume
}

private struct MediaVideoPlayerView: View {
    let item: MediaItem
    let isActive: Bool
    let onLoadState: (String) -> Void
    let onSetBackground: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    let onPagePrev: () -> Void
    let onPageNext: () -> Void

    @StateObject private var controller: MediaVideoController
    @State private var showOverlay = true
    @State private var hideTask: Task<Void, Never>?
    @State private var gamepad = GamepadNavigation.shared
    @State private var focusSlot: VideoFocusSlot = .scrub
    @State private var theme = ThemeManager.shared

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    init(
        item: MediaItem,
        isActive: Bool,
        onLoadState: @escaping (String) -> Void,
        onSetBackground: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onPagePrev: @escaping () -> Void,
        onPageNext: @escaping () -> Void
    ) {
        self.item = item
        self.isActive = isActive
        self.onLoadState = onLoadState
        self.onSetBackground = onSetBackground
        self.onDelete = onDelete
        self.onClose = onClose
        self.onPagePrev = onPagePrev
        self.onPageNext = onPageNext
        _controller = StateObject(wrappedValue: MediaVideoController(url: item.url))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MediaPlayerLayer(player: controller.player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleOverlay()
                }

            if showOverlay {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomControls
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            controller.play()
            scheduleAutoHide()
        }
        .onDisappear {
            controller.pause()
        }
        .onChange(of: isActive) { _, active in
            if active { controller.play() } else { controller.pause() }
        }
        .onChange(of: gamepad.actionID) { _, _ in
            guard isActive else { return }
            handleAction()
        }
        .overlay(alignment: .bottom) {
            if gamepad.shellNavInputActive && isActive && showOverlay {
                MediaHintRow(items: videoHintItems())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    private func videoHintItems() -> [MediaHintRow.Chip] {
        var items: [MediaHintRow.Chip] = []
        items.append(.shoulder("L1/R1", title: SakuraL10n.tr("media.controllerHint.prevNext")))
        items.append(.face(.confirm, title: SakuraL10n.tr("media.controllerHint.zoomOrPause")))
        items.append(.face(.back, title: SakuraL10n.tr("media.player.close")))
        items.append(.face(.secondary, title: SakuraL10n.tr("media.viewer.setBackground")))
        if item.sidecar?.savedStateAtStart != nil || item.sidecar?.savedStateAtEnd != nil {
            items.append(.face(.tertiary, title: SakuraL10n.tr("media.viewer.loadSaveState")))
        }
        items.append(.dpad(title: SakuraL10n.tr("media.controllerHint.focusRowVideo")))
        return items
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = item.sidecar?.capturedAt {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 0)

            if let s = item.sidecar?.savedStateAtStart {
                Button {
                    onLoadState(s)
                } label: {
                    Label(SakuraL10n.tr("media.viewer.loadStart"), systemImage: "memorychip")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(theme.accentColor().opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if let e = item.sidecar?.savedStateAtEnd {
                Button {
                    onLoadState(e)
                } label: {
                    Label(SakuraL10n.tr("media.viewer.loadEnd"), systemImage: "memorychip")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(theme.accentColor().opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            scrubBar
            HStack(spacing: 14) {
                Button(action: { controller.togglePlay(); showOverlayBriefly() }) {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)

                speedControl
                volumeControl

                Spacer(minLength: 0)

                Button(action: { onSetBackground(); showOverlayBriefly() }) {
                    Image(systemName: "photo.fill.on.rectangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                Button(action: { onDelete(); showOverlayBriefly() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.red)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .padding(.top, 18)
        .background(
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var scrubBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(format(controller.currentTime))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                ScrubBar(
                    value: Binding(
                        get: { controller.currentTime },
                        set: { controller.seekTo($0) }
                    ),
                    range: 0...max(controller.duration, 0.1),
                    tint: theme.accentColor(),
                    isFocused: focusSlot == .scrub
                )
                .frame(height: 22)
                Text(format(controller.duration))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(focusSlot == .scrub ? theme.accentColor() : .clear, lineWidth: 1.5)
        )
    }

    private var speedControl: some View {
        Button(action: cycleSpeed) {
            Text(String(format: "%.2gx", controller.rate))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(
                    Capsule().fill(focusSlot == .speed ? theme.accentColor().opacity(0.85) : Color.black.opacity(0.55))
                )
                .overlay(
                    Capsule().stroke(theme.accentColor(), lineWidth: focusSlot == .speed ? 2 : 0)
                )
        }
        .buttonStyle(.plain)
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: controller.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            ScrubBar(
                value: Binding(
                    get: { Double(controller.volume) },
                    set: { controller.setVolume(Float($0)) }
                ),
                range: 0...1,
                tint: focusSlot == .volume ? theme.accentColor() : Color.white.opacity(0.7),
                isFocused: focusSlot == .volume
            )
            .frame(width: 90, height: 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(focusSlot == .volume ? theme.accentColor() : .clear, lineWidth: 1.5)
        )
    }

    private func cycleSpeed() {
        let cur = controller.rate
        let i = speeds.firstIndex(where: { abs($0 - cur) < 0.01 }) ?? 2
        let next = speeds[(i + 1) % speeds.count]
        controller.setRate(next)
        showOverlayBriefly()
    }

    private func handleAction() {
        guard let action = gamepad.lastAction else { return }
        switch action {
        case .back:
            SFXManager.shared.play(.back)
            onClose()
        case .confirm:
            controller.togglePlay()
            showOverlayBriefly()
        case .secondary:
            onSetBackground()
            showOverlayBriefly()
        case .tertiary:
            if let s = item.sidecar?.savedStateAtStart {
                onLoadState(s)
            } else if let e = item.sidecar?.savedStateAtEnd {
                onLoadState(e)
            }
            showOverlayBriefly()
        case .moveLeft:
            switch focusSlot {
            case .scrub: controller.seekBy(-10)
            case .speed: cycleSpeed()
            case .volume: controller.setVolume(controller.volume - 0.05)
            }
            showOverlayBriefly()
        case .moveRight:
            switch focusSlot {
            case .scrub: controller.seekBy(10)
            case .speed: cycleSpeed()
            case .volume: controller.setVolume(controller.volume + 0.05)
            }
            showOverlayBriefly()
        case .moveUp:
            cycleFocus(-1)
        case .moveDown:
            cycleFocus(1)
        case .shoulderLeft:
            onPagePrev()
        case .shoulderRight:
            onPageNext()
        case .triggerLeft, .triggerRight:
            break
        default:
            break
        }
    }

    private func cycleFocus(_ delta: Int) {
        let all = VideoFocusSlot.allCases
        guard let i = all.firstIndex(of: focusSlot) else { return }
        let n = all.count
        focusSlot = all[((i + delta) % n + n) % n]
        SFXManager.shared.play(.navigate)
        showOverlayBriefly()
    }

    private func toggleOverlay() {
        withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
        scheduleAutoHide()
    }

    private func showOverlayBriefly() {
        withAnimation(.easeInOut(duration: 0.15)) { showOverlay = true }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) { showOverlay = false }
            }
        }
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let sec = Int(t)
        let m = sec / 60
        let s = sec % 60
        if m >= 60 {
            let h = m / 60
            let mm = m % 60
            return String(format: "%d:%02d:%02d", h, mm, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Scrub bar (custom slider)

private struct ScrubBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color
    let isFocused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: 4)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, fill(in: geo.size.width)), height: 4)
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(tint, lineWidth: isFocused ? 2 : 0))
                    .frame(width: isFocused ? 14 : 10, height: isFocused ? 14 : 10)
                    .offset(x: max(0, fill(in: geo.size.width) - (isFocused ? 7 : 5)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let pct = max(0, min(1, v.location.x / max(1, geo.size.width)))
                        value = range.lowerBound + pct * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }

    private func fill(in width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let pct = (value - range.lowerBound) / span
        return CGFloat(max(0, min(1, pct))) * width
    }
}

// MARK: - Image overlay (shared)

private struct MediaPlayerOverlay: View {
    let item: MediaItem
    let isVideo: Bool
    let onLoadState: (String) -> Void
    let onSetBackground: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var theme = ThemeManager.shared

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)

                Text(item.url.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: onSetBackground) {
                    Image(systemName: "photo.fill.on.rectangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)

                if let s = item.sidecar?.savedStateAtStart {
                    Button {
                        onLoadState(s)
                    } label: {
                        Image(systemName: "memorychip")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .foregroundStyle(.white)
                            .background(theme.accentColor().opacity(0.85), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.red)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// library-bottom-row look for fullscreen viewer hints
struct MediaHintRow: View {
    enum FaceKind { case confirm, back, secondary, tertiary }

    enum Chip: Identifiable {
        case shoulder(String, title: String)
        case face(FaceKind, title: String)
        case dpad(title: String)

        var id: String {
            switch self {
            case .shoulder(let s, let t): return "s-\(s)-\(t)"
            case .face(let k, let t): return "f-\(k)-\(t)"
            case .dpad(let t): return "d-\(t)"
            }
        }
    }

    let items: [Chip]
    @State private var theme = ThemeManager.shared
    @State private var gamepad = GamepadNavigation.shared

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(items) { item in
                chip(for: item)
            }
        }
    }

    @ViewBuilder
    private func chip(for c: Chip) -> some View {
        switch c {
        case .shoulder(_, let title):
            PSActionBadge(
                systemName: "l1.button.roundedbottom.horizontal",
                psIcon: nil,
                psFallback: nil,
                shoulderSymbol: "l1.button.roundedbottom.horizontal",
                shoulderSymbolSecond: "r1.button.roundedbottom.horizontal",
                title: title,
                tint: theme.color(forKey: "yellow"),
                libraryFooterCompact: true
            )
        case .face(let kind, let title):
            PSActionBadge(
                systemName: faceSystemName(kind),
                psIcon: facePsIcon(kind),
                psFallback: facePsFallback(kind),
                title: title,
                tint: faceTint(kind),
                libraryFooterCompact: true
            )
        case .dpad(let title):
            PSActionBadge(
                systemName: "dpad.fill",
                psIcon: nil,
                psFallback: nil,
                circleGlyphText: nil,
                title: title,
                tint: theme.glassTextPrimary(.dark),
                libraryFooterCompact: true
            )
        }
    }

    private func faceSystemName(_ k: FaceKind) -> String {
        switch k {
        case .confirm: return "play.fill"
        case .back: return "xmark"
        case .secondary: return "photo.fill.on.rectangle.fill"
        case .tertiary: return "memorychip"
        }
    }
    private func facePsIcon(_ k: FaceKind) -> String {
        switch k {
        case .confirm: return "cross"
        case .back: return "circle"
        case .secondary: return "square"
        case .tertiary: return "triangle"
        }
    }
    private func facePsFallback(_ k: FaceKind) -> String {
        switch k {
        case .confirm: return gamepad.confirmLabel
        case .back: return gamepad.backLabel
        case .secondary: return gamepad.secondaryLabel
        case .tertiary: return gamepad.tertiaryLabel
        }
    }
    private func faceTint(_ k: FaceKind) -> Color {
        switch k {
        case .confirm: return theme.color(forKey: "blue")
        case .back: return theme.color(forKey: "red")
        case .secondary: return theme.color(forKey: "pink")
        case .tertiary: return theme.color(forKey: "green")
        }
    }
}
