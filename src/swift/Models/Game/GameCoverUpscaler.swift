// SPDX-License-Identifier: GPL-3.0+

import Foundation
import UIKit

extension Notification.Name {
    static let sakuraCoverUpscaleFinished = Notification.Name("sakura.cover.upscale.finished")
}

/// Runs the neural-texture-art GAN over cached cover images and saves the
/// upscaled version next to the original as `<base>.up.png`.
/// Fully gated behind `neuralUpscaleTextureArt`; no-op when disabled.
final class GameCoverUpscaler: @unchecked Sendable {
    static let shared = GameCoverUpscaler()

    /// Key in userInfo: the serial / metadataKey that was upscaled.
    static let notificationSerialKey = "serial"
    /// Key in userInfo: resolved upscaled-cover file path.
    static let notificationPathKey = "path"

    // serialize inference; each call is heavy on memory and shared with the GS upscale path
    private let queue = DispatchQueue(label: "sakura.cover.upscale", qos: .utility)
    private var inFlight: Set<String> = []
    private let inFlightLock = NSLock()

    private init() {}

    /// Path of the upscaled sibling for a given original cover path (or nil if missing).
    func upscaledSiblingPath(forOriginal originalPath: String) -> String? {
        let sibling = Self.upscaledSiblingURL(forOriginal: URL(fileURLWithPath: originalPath))
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling.path : nil
    }

    // kick off an upscale for a cached cover. safe to call repeatedly. a
    // second call for the same serial is coalesced. serial is only used to
    // tag the completion notification, it does not need to be a PS1 disc serial.
    func upscaleIfNeeded(originalCoverPath: String, serial: String) {
        guard SettingsStore.shared.neuralUpscaleTextureArt else { return }
        let originalURL = URL(fileURLWithPath: originalCoverPath)
        let destURL = Self.upscaledSiblingURL(forOriginal: originalURL)
        let fm = FileManager.default
        // source must exist; skip if upscaled copy already fresh
        guard fm.fileExists(atPath: originalURL.path) else { return }
        if Self.upscaledIsFresh(upscaled: destURL, original: originalURL) {
            NotificationCenter.default.post(
                name: .sakuraCoverUpscaleFinished,
                object: nil,
                userInfo: [
                    Self.notificationSerialKey: serial,
                    Self.notificationPathKey: destURL.path,
                ]
            )
            return
        }

        let taskKey = originalURL.path
        inFlightLock.lock()
        let inserted = inFlight.insert(taskKey).inserted
        inFlightLock.unlock()
        guard inserted else { return }

        queue.async { [weak self] in
            defer {
                self?.inFlightLock.lock()
                self?.inFlight.remove(taskKey)
                self?.inFlightLock.unlock()
            }
            guard SettingsStore.shared.neuralUpscaleTextureArt else { return }
            guard let src = UIImage(contentsOfFile: originalURL.path) else { return }
            // kick a background model load if not loaded yet, but keep going.
            // processNeuralTextureArtUIImage: blocks until inference finishes,
            // which is what we want here (off the main and render threads).
            guard let upscaled = SakuraBridge.processNeuralTextureArtUIImage(src) else { return }
            // when the feature is off mid-task or inference fails, the bridge returns
            // the same UIImage instance; don't persist a pointless copy.
            if upscaled === src { return }
            guard let png = upscaled.pngData() else { return }
            do {
                try png.write(to: destURL, options: .atomic)
            } catch {
                SakuraLogUnified("Library", "Warning", "cover upscale write failed: \(error.localizedDescription)")
                return
            }
            NotificationCenter.default.post(
                name: .sakuraCoverUpscaleFinished,
                object: nil,
                userInfo: [
                    Self.notificationSerialKey: serial,
                    Self.notificationPathKey: destURL.path,
                ]
            )
        }
    }

    /// Remove every cached `.up.png` so a future render regenerates with the
    /// currently-selected model. Called when the model token changes.
    func invalidateAllUpscaledCovers(in coversDir: URL) {
        queue.async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: coversDir.path) else { return }
            for name in entries where name.hasSuffix(".up.png") {
                try? fm.removeItem(at: coversDir.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Helpers

    private static func upscaledSiblingURL(forOriginal original: URL) -> URL {
        let base = original.deletingPathExtension().lastPathComponent
        return original.deletingLastPathComponent().appendingPathComponent("\(base).up.png")
    }

    private static func upscaledIsFresh(upscaled: URL, original: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: upscaled.path) else { return false }
        guard let up = try? fm.attributesOfItem(atPath: upscaled.path),
              let src = try? fm.attributesOfItem(atPath: original.path),
              let upDate = up[.modificationDate] as? Date,
              let srcDate = src[.modificationDate] as? Date
        else { return true }
        return upDate >= srcDate
    }
}
