// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UniformTypeIdentifiers

@Observable
final class FileImportHandler: @unchecked Sendable {
    static let shared = FileImportHandler()

    var lastImportMessage: String?
    var showImportAlert = false

    private static let biosExtensions: Set<String> = ["bin", "rom", "nvm", "mec", "scph"]
    private static let gameExtensions: Set<String> = [
        "iso", "chd", "img", "cso", "zso", "cue", "cua",
        "gz", "mdf", "mds", "nrg", "cdi", "elf",
        "pbp", "m3u", "toc", "ccd", "sub",
        "psx", "ecm"
    ]
    private static let cueExtensions: Set<String> = ["cue", "cua"]
    private static let biosSizeThreshold: UInt64 = 50 * 1024 * 1024

    private init() {}

    // MARK: - Import

    func handleURL(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            importDirectory(url)
            return
        }

        let result = importSingleFile(url, gamesSubfolder: nil)
        lastImportMessage = result.message
        showImportAlert = true
    }

    // MARK: - Directory import

    private struct ImportResult {
        let message: String
        let imported: Int
        let skipped: Int
        let category: String
        let failedToCopy: Bool

        init(
            message: String,
            imported: Int,
            skipped: Int,
            category: String,
            failedToCopy: Bool
        ) {
            self.message = message
            self.imported = imported
            self.skipped = skipped
            self.category = category
            self.failedToCopy = failedToCopy
        }
    }

    private func localizedGameCountLabel(_ games: Int) -> String {
        if games <= 0 { return "" }
        return games == 1
            ? SakuraL10n.tr("ui.import.gamesCountOne")
            : SakuraL10n.trf("ui.import.gamesCountMany", games)
    }

    private func localizedBiosCountLabel(_ bios: Int) -> String {
        if bios <= 0 { return "" }
        return bios == 1 ? SakuraL10n.tr("ui.import.biosCountOne") : SakuraL10n.trf("ui.import.biosCountMany", bios)
    }

    private func localizedSingleImport(category: String, fileName: String, cueSidecarExtras: Int) -> String {
        let base: String
        switch category {
        case "Game":
            base = SakuraL10n.trf("ui.import.done.gameFmt", fileName)
        case "BIOS":
            base = SakuraL10n.trf("ui.import.done.biosFmt", fileName)
        case "Sidecar":
            base = SakuraL10n.trf("ui.import.done.sidecarFmt", fileName)
        default:
            base = SakuraL10n.trf("ui.import.done.fileFmt", fileName)
        }
        guard cueSidecarExtras > 0 else { return base }
        let extras = cueSidecarExtras == 1
            ? SakuraL10n.tr("ui.import.cueSidecarsOneFmt")
            : SakuraL10n.trf("ui.import.cueSidecarsManyFmt", cueSidecarExtras)
        return base + " " + extras
    }

    private func importDirectory(_ folderURL: URL) {
        let docsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let gamesRoot = (docsPath as NSString).appendingPathComponent("Games")
        try? FileManager.default.createDirectory(atPath: gamesRoot, withIntermediateDirectories: true)

        let fm = FileManager.default
        let baseName = folderURL.lastPathComponent
        var games = 0
        var bioses = 0
        var skipped = 0
        var firstError: String?

        guard let enumerator = fm.enumerator(at: folderURL,
                                             includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles]) else {
            lastImportMessage = SakuraL10n.trf("ui.import.folderReadFailFmt", baseName)
            showImportAlert = true
            return
        }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            let ext = fileURL.pathExtension.lowercased()
            let isGame = Self.gameExtensions.contains(ext)
            let isBIOS = Self.biosExtensions.contains(ext)
            let isCueSidecar = ext == "bin" || ext == "sub" || ext == "img" || ext == "ccd"
            if !isGame && !isBIOS && !isCueSidecar {
                skipped += 1
                continue
            }

            let relative = fileURL.path.replacingOccurrences(of: folderURL.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let subfolder = (baseName as NSString)
                .appendingPathComponent((relative as NSString).deletingLastPathComponent)

            let result = importSingleFile(fileURL, gamesSubfolder: subfolder)
            if result.imported > 0 {
                switch result.category {
                case "BIOS": bioses += result.imported
                case "Game": games += result.imported
                default: break
                }
            } else {
                skipped += result.skipped
                if firstError == nil, result.failedToCopy {
                    firstError = result.message
                }
            }
        }

        if let err = firstError, games == 0 && bioses == 0 {
            lastImportMessage = err
        } else {
            var parts: [String] = []
            let g = localizedGameCountLabel(games)
            let b = localizedBiosCountLabel(bioses)
            if !g.isEmpty { parts.append(g) }
            if !b.isEmpty { parts.append(b) }
            if parts.isEmpty {
                lastImportMessage = SakuraL10n.trf("ui.import.folderEmptyFmt", baseName)
            } else {
                let sep = SakuraL10n.tr("ui.import.summarySeparator")
                let summary = parts.joined(separator: sep)
                let suffix = skipped > 0 ? SakuraL10n.trf("ui.import.skippedSuffixFmt", skipped) : ""
                lastImportMessage = SakuraL10n.trf("ui.import.folderBatchFmt", summary, baseName, suffix)
            }
        }
        showImportAlert = true
    }

    // MARK: - Single-file import

    @discardableResult
    private func importSingleFile(_ url: URL, gamesSubfolder: String?) -> ImportResult {
        let ext = url.pathExtension.lowercased()
        let fileName = normalizedFileName(for: url)
        let docsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!

        let destDir: String
        let category: String

        if Self.gameExtensions.contains(ext) {
            let gamesRoot = (docsPath as NSString).appendingPathComponent("Games")
            if let sub = gamesSubfolder, !sub.isEmpty {
                destDir = (gamesRoot as NSString).appendingPathComponent(sub)
            } else {
                destDir = gamesRoot
            }
            category = "Game"
        } else if Self.biosExtensions.contains(ext) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs?[.size] as? UInt64 ?? 0
            if ext == "bin" && size > Self.biosSizeThreshold {
                let gamesRoot = (docsPath as NSString).appendingPathComponent("Games")
                if let sub = gamesSubfolder, !sub.isEmpty {
                    destDir = (gamesRoot as NSString).appendingPathComponent(sub)
                } else {
                    destDir = gamesRoot
                }
                category = "Game"
            } else {
                destDir = (docsPath as NSString).appendingPathComponent("bios")
                category = "BIOS"
            }
        } else if ext == "bin" || ext == "sub" || ext == "img" || ext == "ccd" {
            let gamesRoot = (docsPath as NSString).appendingPathComponent("Games")
            if let sub = gamesSubfolder, !sub.isEmpty {
                destDir = (gamesRoot as NSString).appendingPathComponent(sub)
            } else {
                destDir = gamesRoot
            }
            category = "Sidecar"
        } else {
            return ImportResult(
                message: SakuraL10n.trf("ui.import.unsupportedTypeFmt", ext),
                imported: 0,
                skipped: 1,
                category: "Unknown",
                failedToCopy: false
            )
        }

        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        let destPath = (destDir as NSString).appendingPathComponent(fileName)

        do {
            try copyReplacing(url, to: URL(fileURLWithPath: destPath))
            var extra = 0
            if category == "Game" {
                extra = try copyCueSidecars(for: url, importedName: fileName, to: URL(fileURLWithPath: destDir))
            }
            let label = localizedSingleImport(category: category, fileName: fileName, cueSidecarExtras: extra)
            return ImportResult(
                message: label,
                imported: 1,
                skipped: 0,
                category: category,
                failedToCopy: false
            )
        } catch {
            return ImportResult(
                message: SakuraL10n.trf("ui.import.copyFailedFmt", error.localizedDescription),
                imported: 0,
                skipped: 1,
                category: category,
                failedToCopy: true
            )
        }
    }

    // MARK: - Copy / cue sidecars

    private func normalizedFileName(for url: URL) -> String {
        guard url.pathExtension.lowercased() == "cua" else {
            return url.lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent + ".cue"
    }

    private func copyReplacing(_ source: URL, to destination: URL) throws {
        if source.standardizedFileURL.path == destination.standardizedFileURL.path {
            return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func copyCueSidecars(for url: URL, importedName: String, to destDir: URL) throws -> Int {
        let ext = url.pathExtension.lowercased()
        var copied = 0

        if Self.cueExtensions.contains(ext) {
            let refs = referencedFiles(inCueAt: url)
            for ref in refs {
                let source = url.deletingLastPathComponent().appendingPathComponent(ref)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try copyReplacing(source, to: destDir.appendingPathComponent(source.lastPathComponent))
                copied += 1
            }
            return copied
        }

        guard ext == "bin" else { return 0 }

        let folder = url.deletingLastPathComponent()
        let siblingNames = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let matchingCues = siblingNames.filter { name in
            Self.cueExtensions.contains((name as NSString).pathExtension.lowercased()) &&
            referencedFiles(inCueAt: folder.appendingPathComponent(name)).contains { ref in
                ref.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame
            }
        }

        for cueName in matchingCues {
            let cueURL = folder.appendingPathComponent(cueName)
            let cueDestName = normalizedFileName(for: cueURL)
            if cueDestName != importedName {
                try copyReplacing(cueURL, to: destDir.appendingPathComponent(cueDestName))
                copied += 1
            }

            for ref in referencedFiles(inCueAt: cueURL) {
                let source = folder.appendingPathComponent(ref)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                if source.lastPathComponent.caseInsensitiveCompare(importedName) == .orderedSame { continue }
                try copyReplacing(source, to: destDir.appendingPathComponent(source.lastPathComponent))
                copied += 1
            }
        }

        return copied
    }

    private func referencedFiles(inCueAt url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ??
            (try? String(contentsOf: url, encoding: .isoLatin1))
        guard let text else { return [] }
        var refs: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.range(of: #"^FILE\s+"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }

            if let firstQuote = line.firstIndex(of: "\""),
               let secondQuote = line[line.index(after: firstQuote)...].firstIndex(of: "\"") {
                refs.append(String(line[line.index(after: firstQuote)..<secondQuote]))
                continue
            }

            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2 {
                refs.append(String(parts[1]))
            }
        }

        return refs
    }
}
