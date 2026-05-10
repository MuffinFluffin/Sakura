// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import AVFoundation

@MainActor
final class SplashVideoController: ObservableObject {
    static let shared = SplashVideoController()
    
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    
    func prewarm(url: URL) {
        if player != nil { return }
        _ = AudioSession.shared.ensureActiveForUIAudio()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let queue = AVQueuePlayer(playerItem: item)
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        queue.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.play()
        player = queue
    }
    
    func stop() {
        player?.pause()
        player = nil
        looper = nil
    }
}

@MainActor
struct SplashVideoPlayerView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> SplashPlayerContainerView {
        let view = SplashPlayerContainerView()
        SplashVideoController.shared.prewarm(url: url)
        view.playerLayer.player = SplashVideoController.shared.player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateUIView(_ uiView: SplashPlayerContainerView, context: Context) {}
    
    static func dismantleUIView(_ uiView: SplashPlayerContainerView, coordinator: ()) {
        uiView.playerLayer.player = nil
        SplashVideoController.shared.stop()
    }
}

final class SplashPlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        clipsToBounds = true
    }
}

struct SplashView: View {
    /// Minimum time the splash stays visible after the cherry blossom video is actually rendering.
    var dwellDuration: TimeInterval = 1.45
    /// Hard ceiling so we never get stuck if the video never reports ready.
    var maxWaitForVideo: TimeInterval = 4.0
    // short dwell when we never got the video, exit fast so the user does not stare at a static word mark.
    var noVideoDwellDuration: TimeInterval = 0.4
    var fadeDuration: TimeInterval = 0.42

    var onFinish: () -> Void

    @State private var opacity: Double = 1.0
    @State private var started = false
    @State private var dismissed = false
    @State private var videoReady = false
    @State private var theme = ThemeManager.shared

    private var splashVideoURL: URL? {
        let stem = ThemeManager.cherryBlossomsBackdrop
        return Bundle.main.url(forResource: stem, withExtension: "mp4")
            ?? Bundle.main.url(forResource: stem, withExtension: "mov")
    }

    var body: some View {
        ZStack {
            if theme.increaseContrast {
                theme.splashGradient()
                    .ignoresSafeArea()
            } else if let url = splashVideoURL {
                Color(red: 0.06, green: 0.05, blue: 0.06)
                    .ignoresSafeArea()
                SplashVideoPlayerView(url: url)
                    .ignoresSafeArea()
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            } else {
                theme.splashGradient()
                    .ignoresSafeArea()
            }

            Text(SakuraL10n.tr("brand.appName"))
                .font(.system(size: 56, weight: .black, design: .rounded))
                .tracking(2)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            theme.accentColor(),
                            theme.accentColor().opacity(0.88),
                            theme.accentColor().opacity(0.45),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
        }
        .opacity(opacity)
        .allowsHitTesting(opacity > 0.02)
        .onAppear {
            guard !started else { return }
            started = true
            beginSequence()
        }
    }

    private func beginSequence() {
        // if we have no video or contrast mode is on, dismiss quickly. nothing to watch.
        guard !theme.increaseContrast, let url = splashVideoURL else {
            scheduleFade(after: noVideoDwellDuration)
            return
        }

        // Kick off playback if not already prewarmed
        SplashVideoController.shared.prewarm(url: url)

        // Wait until AVPlayer reports it's actually playing, then start the dwell timer so the
        // user actually sees the cherry blossom motion. A hard ceiling guarantees we never hang.
        let deadline = Date().addingTimeInterval(maxWaitForVideo)
        pollForPlayback(deadline: deadline)
    }

    private func pollForPlayback(deadline: Date) {
        guard !dismissed else { return }
        let player = SplashVideoController.shared.player
        let isPlaying = (player?.rate ?? 0) > 0.01
            && (player?.currentItem?.status == .readyToPlay)
        if isPlaying {
            videoReady = true
            scheduleFade(after: dwellDuration)
            return
        }
        if Date() >= deadline {
            // never saw the video ready. do not hold the static word mark, fade out fast.
            scheduleFade(after: noVideoDwellDuration)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pollForPlayback(deadline: deadline)
        }
    }

    private func scheduleFade(after delay: TimeInterval) {
        guard !dismissed else { return }
        dismissed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeOut(duration: fadeDuration)) {
                opacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration + 0.05) {
                onFinish()
            }
        }
    }
}
