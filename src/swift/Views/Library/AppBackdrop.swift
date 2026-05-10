// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import AVFoundation
import UIKit

struct AppBackdrop: View {
    @Bindable private var theme = ThemeManager.shared

    private let sakuraTop    = Color(red: 0.99, green: 0.82, blue: 0.89)
    private let sakuraBottom = Color(red: 0.45, green: 0.13, blue: 0.30)

    private let onyxTop      = Color(red: 0.07, green: 0.08, blue: 0.09)
    private let onyxBottom   = Color(red: 0.02, green: 0.02, blue: 0.03)

    private let whiteoutTop    = Color(red: 0.96, green: 0.95, blue: 0.93)
    private let whiteoutBottom = Color(red: 0.82, green: 0.82, blue: 0.82)

    private var gradientColors: [Color] {
        switch theme.backdropKey {
        case "onyx":     return [onyxTop, onyxBottom]
        case "whiteout": return [whiteoutTop, whiteoutBottom]
        default:         return [sakuraTop, sakuraBottom]
        }
    }

    private var mediaOpacity: Double {
        min(max(theme.bgMediaOpacity, 0), 1)
    }

    private var backdropMediaIdentity: String {
        let trimmed = theme.bgMediaFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(theme.bgMediaType)::\(trimmed)"
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            ZStack {
                if theme.increaseContrast {
                    Color(red: 0.05, green: 0.05, blue: 0.05)
                        .frame(width: w, height: h)
                } else {
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: w, height: h)

                    mediaLayer(width: w, height: h)

                    if theme.bgTintEnabled && !theme.differentiateWithoutColor {
                        theme.bgTintGradient()
                            .frame(width: w, height: h)
                            .blendMode(.softLight)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(width: w, height: h, alignment: .center)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func mediaLayer(width: CGFloat, height: CGFloat) -> some View {
        if let url = theme.backgroundMediaURL() {
            switch theme.bgMediaType {
            case "image":
                BackdropImageView(url: url)
                    .opacity(mediaOpacity)
                    .frame(width: width, height: height)
                    .id(backdropMediaIdentity)
            case "video":
                BackdropVideoFillView(url: url, opacity: mediaOpacity)
                    .frame(width: width, height: height)
                    .id(backdropMediaIdentity)
            default:
                EmptyView()
            }
        }
    }
}

private struct BackdropImageView: View {
    let url: URL

    var body: some View {
        Group {
            if let ui = UIImage(contentsOfFile: url.path) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }
}

@MainActor
final class BackgroundVideo {
    static let shared = BackgroundVideo()

    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    private var statusObservation: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?
    private var failureRecoveryCount = 0

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioSessionInterrupted), name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc private func appBecameActive() {
        resumePlaybackIfNeeded()
    }

    @objc private func appWillEnterForeground() {
        resumePlaybackIfNeeded()
    }

    @objc private func audioSessionInterrupted(_ note: Notification) {
        guard let info = note.userInfo,
              let kind = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              kind == AVAudioSession.InterruptionType.ended.rawValue
        else { return }
        resumePlaybackIfNeeded()
    }

    private func resumePlaybackIfNeeded() {
        guard let p = player else { return }
        _ = AudioSession.shared.ensureActiveForUIAudio()
        if p.rate < 0.01 { p.play() }
    }

    static func canonicalBackdropPathKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func sameTrackedMediaURL(as url: URL) -> Bool {
        guard let cur = currentURL else { return false }
        return Self.canonicalBackdropPathKey(for: cur) == Self.canonicalBackdropPathKey(for: url)
    }

    // returns the shared player without touching playback when URL already matches. avoids glitching the mute backdrop video when sliders re-render SwiftUI each frame.
    func player(for url: URL) -> AVQueuePlayer {
        if sameTrackedMediaURL(as: url), let p = player { return p }
        stopPlaybackKeepingURLForSwitch()
        currentURL = url.standardizedFileURL
        failureRecoveryCount = 0

        _ = AudioSession.shared.ensureActiveForUIAudio()

        let queue = makeLooperQueue(url: url.standardizedFileURL)
        player = queue
        wireItemObservers(queue)
        queue.play()
        return queue
    }

    private func makeLooperQueue(url: URL) -> AVQueuePlayer {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let queue = AVQueuePlayer(playerItem: item)
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        queue.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: queue, templateItem: item)
        return queue
    }

    private func stopPlaybackKeepingURLForSwitch() {
        clearItemObservers()
        looper = nil
        player?.pause()
        player = nil
    }

    private func clearItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
    }

    private func wireItemObservers(_ queue: AVQueuePlayer) {
        clearItemObservers()
        guard let item = queue.currentItem else { return }

        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self, weak queue] it, _ in
            Task { @MainActor in
                guard let self else { return }
                if it.status == .readyToPlay {
                    _ = AudioSession.shared.ensureActiveForUIAudio()
                    if (queue?.rate ?? 0) < 0.01 { queue?.play() }
                }
                guard it.status == .failed else { return }
                guard it === self.player?.currentItem else { return }
                self.recoverFromPlaybackFailure()
            }
        }

        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                _ = AudioSession.shared.ensureActiveForUIAudio()
                if let p = self?.player, p.rate < 0.01 { p.play() }
            }
        }
    }

    private func recoverFromPlaybackFailure() {
        guard let url = currentURL else { return }
        guard failureRecoveryCount < 6 else { return }
        failureRecoveryCount += 1
        stopPlaybackKeepingURLForSwitch()
        _ = AudioSession.shared.ensureActiveForUIAudio()
        let queue = makeLooperQueue(url: url.standardizedFileURL)
        player = queue
        wireItemObservers(queue)
        queue.play()
    }

    func teardown() {
        clearItemObservers()
        looper = nil
        player?.pause()
        player = nil
        currentURL = nil
        failureRecoveryCount = 0
    }
}

struct BackdropVideoFillView: UIViewRepresentable {
    let url: URL
    var videoGravity: AVLayerVideoGravity = .resize
    var opacity: Double = 1

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .clear
        view.videoGravity = videoGravity
        view.alpha = CGFloat(min(max(opacity, 0), 1))
        view.attach(url: url)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.alpha = CGFloat(min(max(opacity, 0), 1))
        uiView.videoGravity = videoGravity
        uiView.attach(url: url)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: ()) {
        uiView.detach()
    }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        backgroundColor = .clear
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var videoGravity: AVLayerVideoGravity = .resize {
        didSet {
            if playerLayer.videoGravity != videoGravity {
                playerLayer.videoGravity = videoGravity
            }
        }
    }

    private var attachedPathKey: String?

    func attach(url: URL) {
        playerLayer.videoGravity = videoGravity
        let key = BackgroundVideo.canonicalBackdropPathKey(for: url)
        if attachedPathKey != key {
            attachedPathKey = key
            let p = BackgroundVideo.shared.player(for: url)
            if playerLayer.player !== p {
                playerLayer.player = p
            }
        }
        setNeedsLayout()
    }

    func detach() {
        attachedPathKey = nil
        playerLayer.player = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
