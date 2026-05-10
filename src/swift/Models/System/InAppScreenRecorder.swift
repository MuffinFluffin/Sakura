// SPDX-License-Identifier: GPL-3.0+

import AVFoundation
import Combine
import CoreImage
import Foundation
import Photos
import ReplayKit
import UIKit

private final class AVAssetWriterFinishBox: @unchecked Sendable {
    let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) { self.writer = writer }
}

@MainActor
final class InAppScreenRecorder: NSObject, ObservableObject {
    static let shared = InAppScreenRecorder()

    @Published private(set) var isRecording = false

    private let recorder = RPScreenRecorder.shared()
    private var activeOutputURL: URL?
    private var pendingStartOutputURL: URL?

    private var usesReplayKitForCurrentRecording = true
    private var metalAssetWriter: AVAssetWriter?
    private var metalVideoInput: AVAssetWriterInput?
    private var metalAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var metalDisplayLink: CADisplayLink?
    private var metalSessionClockStart: CFTimeInterval?
    private var metalVideoWidth: Int = 0
    private var metalVideoHeight: Int = 0
    private let metalCIContext = CIContext(options: [.cacheIntermediates: false])
    private var metalFramesAppended = 0

    private override init() {
        super.init()
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    static func screenRecordingsDirectory() -> URL {
        let base = URL(fileURLWithPath: SakuraBridge.documentsDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("ScreenRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Screenshots live in their own folder now so the Files app / iCloud sync
    // shows them as a discrete bucket instead of being mixed in with video
    // recordings. The media library scanner reads both folders.
    static func screenshotsDirectory() -> URL {
        let base = URL(fileURLWithPath: SakuraBridge.documentsDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sanitizedGameSlugForMediaFilename() -> String {
        let path = SakuraBridge.currentISOPath() ?? ""
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        if base.isEmpty { return "game" }
        let lower = base.lowercased().replacingOccurrences(of: " ", with: "-")
        let mapped = lower.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { return ch }
            return "-"
        }
        var collapsed = String(mapped).replacingOccurrences(of: "--", with: "-")
        while collapsed.contains("--") {
            collapsed = collapsed.replacingOccurrences(of: "--", with: "-")
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if trimmed.isEmpty { return "game" }
        return String(trimmed.prefix(80))
    }

    /// `attachEmbeddedSaveSnapshot`: when false, skips writing `.metadata/*.state` blobs for gallery items (slot saves still get their own `*.preview.png` from the core).
    func captureGameplayScreenshotPNG(attachEmbeddedSaveSnapshot: Bool = true) {
        let mv = RenderHost.shared.metalView
        mv.layoutIfNeeded()
        let bounds = mv.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            SakuraLogUnified("Screenshot", "Warning", "game view bounds too small")
            return
        }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = UIScreen.main.scale
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: fmt)
        let image = renderer.image { _ in
            mv.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let png = image.pngData() else {
            SakuraLogUnified("Screenshot", "Warning", "png encode failed")
            return
        }
        let iso = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let leaf = "sakura-\(Self.sanitizedGameSlugForMediaFilename())-\(iso)"
        let leafPng = "\(leaf).png"
        // PNG + JSON sidecar + .metadata/* all live together under Screenshots/
        // (their own folder now, no longer mixed with ScreenRecordings mp4s).
        let folder = Self.screenshotsDirectory()
        let url = folder.appendingPathComponent(leafPng)
        do {
            try png.write(to: url, options: .atomic)
            Self.finishStillMediaOutput(url: url)

            var sidecar = MediaSidecar(
                isoName: SakuraBridge.currentISOPath(),
                capturedAt: Date(),
                savedStateAtStart: nil as String?,
                savedStateAtEnd: nil as String?,
                durationSeconds: nil as Double?
            )

            if attachEmbeddedSaveSnapshot,
               SettingsStore.shared.mediaAttachStateOnScreenshot,
               SakuraBridge.isEmulationRunning() {
                let metaDir = folder.appendingPathComponent(".metadata")
                try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
                let stateName = "\(leaf).start.state"
                let statePath = metaDir.appendingPathComponent(stateName).path
                if SakuraBridge.writeSaveStateBytes(toPath: statePath) {
                    sidecar.savedStateAtStart = stateName
                }
            }

            if let sidecarData = try? JSONEncoder().encode(sidecar) {
                let sidecarUrl = folder.appendingPathComponent("\(leaf).json")
                try? sidecarData.write(to: sidecarUrl, options: Data.WritingOptions.atomic)
            }
        } catch {
            SakuraLogUnified("Screenshot", "Warning", "write failed: \(error.localizedDescription)")
        }
    }

    private func makeOutputURL() -> URL {
        let iso = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let leaf = "sakura-\(Self.sanitizedGameSlugForMediaFilename())-\(iso).mp4"
        return Self.screenRecordingsDirectory().appendingPathComponent(leaf)
    }

    private func metalRecordingDimensions(layer: CAMetalLayer, view: UIView) -> (Int, Int) {
        var w = Int(layer.drawableSize.width.rounded(.down))
        var h = Int(layer.drawableSize.height.rounded(.down))
        if w < 16 || h < 16 {
            let scale = max(1.0, view.window?.screen.scale ?? UIScreen.main.scale)
            w = max(16, Int((view.bounds.width * scale).rounded(.down)))
            h = max(16, Int((view.bounds.height * scale).rounded(.down)))
        }
        w -= w % 2
        h -= h % 2
        return (max(2, w), max(2, h))
    }

    private func metalBitrate(width: Int, height: Int) -> Int {
        let px = width * height
        return min(28_000_000, max(2_400_000, px * 5))
    }

    private func tearDownMetalRecordingScratch() {
        metalDisplayLink?.invalidate()
        metalDisplayLink = nil
        metalAssetWriter = nil
        metalVideoInput = nil
        metalAdaptor = nil
        metalSessionClockStart = nil
        metalFramesAppended = 0
        metalVideoWidth = 0
        metalVideoHeight = 0
    }

    private func startMetalLayerRecording(outputURL: URL) throws {
        tearDownMetalRecordingScratch()
        try? FileManager.default.removeItem(at: outputURL)

        let mv = RenderHost.shared.metalView
        mv.layoutIfNeeded()
        guard let mtlLayer = mv.layer as? CAMetalLayer else {
            throw NSError(domain: "MetalRecord", code: 1, userInfo: [NSLocalizedDescriptionKey: "no CAMetalLayer"])
        }
        let dims = metalRecordingDimensions(layer: mtlLayer, view: mv)
        metalVideoWidth = dims.0
        metalVideoHeight = dims.1

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: metalBitrate(width: metalVideoWidth, height: metalVideoHeight),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: metalVideoWidth,
            AVVideoHeightKey: metalVideoHeight,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "MetalRecord", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot add video input"])
        }
        writer.add(input)

        let pxAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: metalVideoWidth,
            kCVPixelBufferHeightKey as String: metalVideoHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: pxAttrs)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "MetalRecord", code: 3, userInfo: [NSLocalizedDescriptionKey: "startWriting failed"])
        }
        writer.startSession(atSourceTime: .zero)

        metalAssetWriter = writer
        metalVideoInput = input
        metalAdaptor = adaptor

        let link = CADisplayLink(target: self, selector: #selector(metalRecordingDisplayLinkTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        metalDisplayLink = link
    }

    @objc private func metalRecordingDisplayLinkTick(_ link: CADisplayLink) {
        guard usesReplayKitForCurrentRecording == false else { return }
        guard let writer = metalAssetWriter, writer.status == .writing else { return }
        guard let input = metalVideoInput, input.isReadyForMoreMediaData else { return }
        guard let adaptor = metalAdaptor, let pool = adaptor.pixelBufferPool else { return }

        let mv = RenderHost.shared.metalView
        mv.layoutIfNeeded()
        let bounds = mv.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pixelBuffer = pb else { return }

        let scale = UIScreen.main.scale
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = scale
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: fmt)
        let uiImage = renderer.image { _ in
            mv.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        guard let cg = uiImage.cgImage else { return }

        let ci = CIImage(cgImage: cg)
        let ext = ci.extent.integral
        guard ext.width > 1, ext.height > 1 else { return }

        let sx = CGFloat(metalVideoWidth) / ext.width
        let sy = CGFloat(metalVideoHeight) / ext.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        if metalSessionClockStart == nil {
            metalSessionClockStart = link.timestamp
        }
        let t0 = metalSessionClockStart ?? link.timestamp
        let elapsed = max(0, link.timestamp - t0)
        let pts = CMTime(seconds: elapsed, preferredTimescale: 60_000)

        metalCIContext.render(
            scaled,
            to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: metalVideoWidth, height: metalVideoHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        if adaptor.append(pixelBuffer, withPresentationTime: pts) {
            metalFramesAppended += 1
        }
    }

    private func finalizeMetalLayerRecording(outputURL: URL) async -> URL? {
        metalDisplayLink?.invalidate()
        metalDisplayLink = nil

        guard metalAssetWriter != nil else {
            tearDownMetalRecordingScratch()
            return nil
        }

        if metalAssetWriter?.status != .writing || metalFramesAppended == 0 {
            try? FileManager.default.removeItem(at: outputURL)
            SakuraLogUnified("ScreenRecord", "Warning", "metal-layer record wrote no frames")
            tearDownMetalRecordingScratch()
            return nil
        }

        guard let writer = metalAssetWriter else {
            tearDownMetalRecordingScratch()
            return nil
        }

        metalVideoInput?.markAsFinished()
        let box = AVAssetWriterFinishBox(writer)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            box.writer.finishWriting {
                cont.resume()
            }
        }

        let completed = box.writer.status == .completed
        let errMsg = box.writer.error?.localizedDescription ?? "unknown"

        tearDownMetalRecordingScratch()

        if completed {
            return outputURL
        }
        SakuraLogUnified("ScreenRecord", "Warning", "metal-layer writer failed: \(errMsg)")
        try? FileManager.default.removeItem(at: outputURL)
        return nil
    }

    private var activeSidecar: MediaSidecar?

    private func startRecording() {
        guard !isRecording else { return }

        let scopeFull = SettingsStore.shared.effectiveCaptureScope == "full"
        let url = makeOutputURL()

        let slug = url.deletingPathExtension().lastPathComponent
        var sidecar = MediaSidecar(
            isoName: SakuraBridge.currentISOPath(),
            capturedAt: Date(),
            savedStateAtStart: nil as String?,
            savedStateAtEnd: nil as String?,
            durationSeconds: nil as Double?
        )

        if SettingsStore.shared.mediaAttachStateOnRecording != .off && SakuraBridge.isEmulationRunning() {
            let metaDir = Self.screenRecordingsDirectory().appendingPathComponent(".metadata")
            try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
            let stateName = "\(slug).start.state"
            let statePath = metaDir.appendingPathComponent(stateName).path
            if SakuraBridge.writeSaveStateBytes(toPath: statePath) {
                sidecar.savedStateAtStart = stateName
            }
        }
        
        self.activeSidecar = sidecar

        if !scopeFull {
            do {
                try startMetalLayerRecording(outputURL: url)
                usesReplayKitForCurrentRecording = false
                activeOutputURL = url
                pendingStartOutputURL = nil
                isRecording = true
                return
            } catch {
                SakuraLogUnified(
                    "ScreenRecord",
                    "Warning",
                    "metal-layer record unavailable (\(error.localizedDescription)). falling back to ReplayKit"
                )
                tearDownMetalRecordingScratch()
            }
        }

        usesReplayKitForCurrentRecording = true
        guard recorder.isAvailable else {
            SakuraLogUnified("ScreenRecord", "Warning", "screen recording unavailable")
            return
        }
        guard !recorder.isRecording else { return }
        pendingStartOutputURL = url
        recorder.isMicrophoneEnabled = false
        recorder.startRecording { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.pendingStartOutputURL = nil
                    self.activeOutputURL = nil
                    self.isRecording = false
                    SakuraLogUnified("ScreenRecord", "Warning", "screen record start failed: \(error.localizedDescription)")
                    return
                }
                self.activeOutputURL = self.pendingStartOutputURL
                self.pendingStartOutputURL = nil
                self.isRecording = true
            }
        }
    }

    private func stopRecording() {
        if !usesReplayKitForCurrentRecording {
            guard let url = activeOutputURL else {
                isRecording = false
                tearDownMetalRecordingScratch()
                return
            }
            activeOutputURL = nil
            isRecording = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                let done = await finalizeMetalLayerRecording(outputURL: url)
                if let done {
                    self.writeRecordingSidecar(url: done)
                    Self.finishVideoOutput(url: done)
                }
            }
            return
        }

        guard recorder.isRecording else {
            isRecording = false
            activeOutputURL = nil
            return
        }
        guard let url = activeOutputURL else {
            recorder.stopRecording { [weak self] _, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRecording = false
                    if let error {
                        SakuraLogUnified("ScreenRecord", "Warning", "screen record stop failed: \(error.localizedDescription)")
                    }
                }
            }
            return
        }
        recorder.stopRecording(withOutput: url) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRecording = false
                self.activeOutputURL = nil
                if let error {
                    SakuraLogUnified("ScreenRecord", "Warning", "screen record stop failed: \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                
                self.writeRecordingSidecar(url: url)
                Self.finishVideoOutput(url: url)
            }
        }
    }
    
    private func writeRecordingSidecar(url: URL) {
        guard var sidecar = self.activeSidecar else { return }
        self.activeSidecar = nil
        
        if SettingsStore.shared.mediaAttachStateOnRecording == .both && SakuraBridge.isEmulationRunning() {
            let metaDir = Self.screenRecordingsDirectory().appendingPathComponent(".metadata")
            try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
            let stateName = "\(url.deletingPathExtension().lastPathComponent).end.state"
            let statePath = metaDir.appendingPathComponent(stateName).path
            if SakuraBridge.writeSaveStateBytes(toPath: statePath) {
                sidecar.savedStateAtEnd = stateName
            }
        }
        
        let asset = AVAsset(url: url)
        sidecar.durationSeconds = asset.duration.seconds
        
        if let sidecarData = try? JSONEncoder().encode(sidecar) {
            let sidecarUrl = url.deletingPathExtension().appendingPathExtension("json")
            try? sidecarData.write(to: sidecarUrl, options: Data.WritingOptions.atomic)
        }
    }

    private static func finishVideoOutput(url: URL) {
        let dest = SettingsStore.shared.effectiveCaptureDestination
        let leaf = url.lastPathComponent
        if dest == "documents" {
            SakuraNotificationCenter.shared.postSettingChange(
                title: SakuraL10n.tr("emu.recording.savedToast"),
                detail: leaf
            )
            return
        }
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            Task { @MainActor in
                await saveVideoToPhotos(at: url, leaf: leaf, dest: dest)
            }
        case .denied, .restricted:
            SakuraLogUnified("ScreenRecord", "Warning", "photos add not authorized")
        default:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                switch status {
                case .authorized, .limited:
                    Task { @MainActor in
                        await saveVideoToPhotos(at: url, leaf: leaf, dest: dest)
                    }
                default:
                    Task { @MainActor in
                        SakuraLogUnified("ScreenRecord", "Warning", "photos add not authorized")
                    }
                }
            }
        }
    }

    @MainActor
    private static func saveVideoToPhotos(at url: URL, leaf: String, dest: String) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            SakuraNotificationCenter.shared.postSettingChange(
                title: SakuraL10n.tr("emu.recording.savedToast"),
                detail: leaf
            )
            if dest == "photos" {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            SakuraLogUnified(
                "ScreenRecord",
                "Warning",
                "photos save failed: \(error.localizedDescription)"
            )
        }
    }

    private static func finishStillMediaOutput(url: URL) {
        let dest = SettingsStore.shared.effectiveCaptureDestination
        let leaf = url.lastPathComponent
        if dest == "documents" {
            SakuraNotificationCenter.shared.postSettingChange(
                title: SakuraL10n.tr("emu.screenshot.savedToast"),
                detail: leaf
            )
            return
        }
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            Task { @MainActor in
                await saveScreenshotToPhotos(at: url, leaf: leaf, dest: dest)
            }
        case .denied, .restricted:
            SakuraLogUnified("Screenshot", "Warning", "photos add not authorized")
        default:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                switch status {
                case .authorized, .limited:
                    Task { @MainActor in
                        await saveScreenshotToPhotos(at: url, leaf: leaf, dest: dest)
                    }
                default:
                    Task { @MainActor in
                        SakuraLogUnified("Screenshot", "Warning", "photos add not authorized")
                    }
                }
            }
        }
    }

    @MainActor
    private static func saveScreenshotToPhotos(at url: URL, leaf: String, dest: String) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
            SakuraNotificationCenter.shared.postSettingChange(
                title: SakuraL10n.tr("emu.screenshot.savedToast"),
                detail: leaf
            )
            if dest == "photos" {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            SakuraLogUnified(
                "Screenshot",
                "Warning",
                "photos save failed: \(error.localizedDescription)"
            )
        }
    }
}
