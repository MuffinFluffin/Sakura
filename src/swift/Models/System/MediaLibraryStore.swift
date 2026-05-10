// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

enum MediaKind {
    case screenshot
    case recording
    case background
}

struct MediaSidecar: Codable {
    var isoName: String?
    var capturedAt: Date
    var savedStateAtStart: String?
    var savedStateAtEnd: String?
    var durationSeconds: Double?
}

struct MediaItem: Identifiable {
    var id: URL { url }
    let kind: MediaKind
    let url: URL
    let sidecar: MediaSidecar?
    let sizeBytes: UInt64
    let modified: Date
    let isVideo: Bool
}

@MainActor
final class MediaLibraryStore: ObservableObject {
    static let shared = MediaLibraryStore()

    @Published var items: [MediaItem] = []

    private let fm = FileManager.default

    private init() {
        refresh()
    }

    func refresh() {
        var newItems: [MediaItem] = []

        let docs = SakuraBridge.documentsDirectory()

        // ScreenRecordings + Screenshots. Scan both: the new Screenshots/
        // folder is where freshly-captured PNGs go, but older builds dropped
        // screenshots into ScreenRecordings/ alongside the mp4s, so we still
        // pick those up until the user cleans them up or we migrate.
        let scanRoots: [URL] = [
            URL(fileURLWithPath: docs).appendingPathComponent("ScreenRecordings"),
            URL(fileURLWithPath: docs).appendingPathComponent("Screenshots"),
        ]
        for root in scanRoots {
            guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isHiddenKey]) else { continue }
            for file in contents {
                if file.lastPathComponent.hasPrefix(".") { continue }
                let ext = file.pathExtension.lowercased()
                let isVideo = (ext == "mp4" || ext == "mov")
                let isImage = (ext == "png" || ext == "jpg" || ext == "jpeg")
                if !isVideo && !isImage { continue }

                var size: UInt64 = 0
                var mod = Date()
                if let res = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                    size = UInt64(res.fileSize ?? 0)
                    mod = res.contentModificationDate ?? Date()
                }

                let sidecarUrl = file.deletingPathExtension().appendingPathExtension("json")
                var sidecar: MediaSidecar? = nil
                if let data = try? Data(contentsOf: sidecarUrl),
                   let dec = try? JSONDecoder().decode(MediaSidecar.self, from: data) {
                    sidecar = dec
                }

                let kind: MediaKind = isVideo ? .recording : .screenshot
                newItems.append(MediaItem(kind: kind, url: file, sidecar: sidecar, sizeBytes: size, modified: mod, isVideo: isVideo))
            }
        }

        // Backgrounds
        let backgroundsUrl = URL(fileURLWithPath: docs).appendingPathComponent("backgrounds")
        if let contents = try? fm.contentsOfDirectory(at: backgroundsUrl, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isHiddenKey]) {
            for file in contents {
                if file.lastPathComponent.hasPrefix(".") { continue }
                let ext = file.pathExtension.lowercased()
                let isVideo = (ext == "mp4" || ext == "mov")
                let isImage = (ext == "png" || ext == "jpg" || ext == "jpeg")
                if !isVideo && !isImage { continue }

                var size: UInt64 = 0
                var mod = Date()
                if let res = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                    size = UInt64(res.fileSize ?? 0)
                    mod = res.contentModificationDate ?? Date()
                }

                newItems.append(MediaItem(kind: .background, url: file, sidecar: nil, sizeBytes: size, modified: mod, isVideo: isVideo))
            }
        }

        items = newItems.sorted(by: { $0.modified > $1.modified })
    }

    func delete(_ item: MediaItem) {
        try? fm.removeItem(at: item.url)
        if item.kind == .recording || item.kind == .screenshot {
            let sidecarUrl = item.url.deletingPathExtension().appendingPathExtension("json")
            try? fm.removeItem(at: sidecarUrl)

            if let sidecar = item.sidecar {
                let metaDir = item.url.deletingLastPathComponent().appendingPathComponent(".metadata")
                if let s = sidecar.savedStateAtStart {
                    try? fm.removeItem(at: metaDir.appendingPathComponent(s))
                    try? fm.removeItem(at: metaDir.appendingPathComponent((s as NSString).deletingPathExtension + ".preview.png"))
                }
                if let e = sidecar.savedStateAtEnd {
                    try? fm.removeItem(at: metaDir.appendingPathComponent(e))
                    try? fm.removeItem(at: metaDir.appendingPathComponent((e as NSString).deletingPathExtension + ".preview.png"))
                }
            }
            
            let thumbUrl = item.url.deletingLastPathComponent()
                .appendingPathComponent(".metadata")
                .appendingPathComponent(".thumbs")
                .appendingPathComponent(item.url.lastPathComponent)
                .appendingPathExtension("jpg")
            try? fm.removeItem(at: thumbUrl)
        }
        refresh()
    }

    func deleteAll(kind: MediaKind?) {
        for item in items where kind == nil || item.kind == kind {
            delete(item)
        }
    }

    func totalBytes(kind: MediaKind) -> UInt64 {
        items.filter { $0.kind == kind }.map { $0.sizeBytes }.reduce(0, +)
    }

    func setAsBackground(item: MediaItem) -> Bool {
        let destFolder = ThemeManager.backgroundMediaDir
        try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
        
        if item.kind == .background {
            ThemeManager.shared.bgMediaType = item.isVideo ? "video" : "image"
            ThemeManager.shared.bgMediaFilename = item.url.lastPathComponent
            ThemeManager.shared.bgMediaOpacity = 1.0
            return true
        }
        
        let destUrl = destFolder.appendingPathComponent(item.url.lastPathComponent)
        if !fm.fileExists(atPath: destUrl.path) {
            do {
                try fm.copyItem(at: item.url, to: destUrl)
            } catch {
                return false
            }
        }
        
        ThemeManager.shared.bgMediaType = item.isVideo ? "video" : "image"
        ThemeManager.shared.bgMediaFilename = item.url.lastPathComponent
        ThemeManager.shared.bgMediaOpacity = 1.0
        return true
    }
}

enum PendingMediaAttachedSaveKeys {
    static let pathDefaultsKey = "sakura.media.pendingLoadStatePath"
    static let expectedISODefaultsKey = "sakura.media.pendingLoadExpectedISO"

    /// `currentISOPath` ini value vs library `Games/...` slug or screenshot sidecar snapshot.
    static func isoMatchesStoredBoot(launchingOrBootINI: String, storedBootPathOrISOFromSidecar: String) -> Bool {
        if storedBootPathOrISOFromSidecar.isEmpty { return false }
        if launchingOrBootINI == storedBootPathOrISOFromSidecar { return true }
        let bootLeaf = (launchingOrBootINI as NSString).lastPathComponent
        let storeLeaf = (storedBootPathOrISOFromSidecar as NSString).lastPathComponent
        if bootLeaf == storeLeaf { return true }
        if launchingOrBootINI.hasSuffix(storedBootPathOrISOFromSidecar) || storedBootPathOrISOFromSidecar.hasSuffix(bootLeaf) {
            return true
        }
        return false
    }
}
