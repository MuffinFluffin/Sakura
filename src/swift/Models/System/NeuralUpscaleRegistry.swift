// SPDX-License-Identifier: GPL-3.0+

import Foundation

struct NeuralUpscaleFetchableModel: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let sourceURL: URL
    let installKind: InstallKind

    enum InstallKind: Sendable {
        case mlmodel(fileName: String)
        case mlpackageZip(preferBundlePathSubstring: String?)
        /// `sourceURL` must be GitHub Contents API pointing at `.mlpackage` directory (recursive tree download).
        case mlpackageGitHubContents
    }
}

enum NeuralUpscaleRegistry {
    static let bundledINIValue = "bundle"
    private static let bundledINITokenPrefix = "bundled:"
    static let downloadableNeuralPackageFileName = "Sakura-x2-tile128.mlpackage"
    static let frameUpscaleOffToken = "__neural_frame_off__"
    static let importedNeuralModelsFolderName = "NeuralUpscaleModels"
    private static let legacyImportedModelsFolderName = "JKTModels"
    private static let importedModelINITokenPrefix = "neuralimport:"
    private static let legacyImportedModelINITokenPrefix = "jkt:"
    static let legacyImportsFolderName = "NeuralUpscaleImports"

    static func frameUpscaleCycleOptions() -> [(value: String, label: String)] {
        var opts: [(value: String, label: String)] = [(frameUpscaleOffToken, SakuraL10n.tr("common.off"))]
        opts.append(contentsOf: modelPickerOptions().map { ($0.iniValue, displayLabel(forINIToken: $0.iniValue)) })
        return opts
    }

    static func bundledDisplayLabel() -> String {
        SakuraL10n.tr("neural.bundled.fastSrgan")
    }

    static func importedNeuralModelsDirectoryURL() -> URL? {
        let docs = URL(fileURLWithPath: SakuraBridge.documentsDirectory(), isDirectory: true)
        migrateLegacyImportedModelsFolderIfNeeded(docs: docs)
        let dir = docs.appendingPathComponent(importedNeuralModelsFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir
    }

    static func importedNeuralModelURLs() -> [URL] {
        pruneLegacyImportsIfPresent()
        guard let dir = importedNeuralModelsDirectoryURL() else { return [] }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { lower in
            let l = lower.lowercased()
            return l.hasSuffix(".mlmodel") || l.hasSuffix(".mlpackage")
        }
        .sorted()
        .map { dir.appendingPathComponent($0) }
    }

    static func iniTokenForImportedNeuralFile(name: String) -> String {
        "\(importedModelINITokenPrefix)\(name)"
    }

    static func isAllowedImportedNeuralFileName(_ name: String) -> Bool {
        name.caseInsensitiveCompare(Self.downloadableNeuralPackageFileName) == .orderedSame
    }

    static func normalizedNeuralModelINIToken(_ token: String) -> String {
        if token.hasPrefix(legacyImportedModelINITokenPrefix) {
            return importedModelINITokenPrefix + String(token.dropFirst(legacyImportedModelINITokenPrefix.count))
        }
        return token
    }

    static func displayLabel(forINIToken token: String) -> String {
        if token == bundledINIValue || token.isEmpty {
            return bundledDisplayLabel()
        }
        if token.hasPrefix(bundledINITokenPrefix) {
            return String(token.dropFirst(bundledINITokenPrefix.count))
        }
        if token.hasPrefix(importedModelINITokenPrefix) {
            let rest = String(token.dropFirst(importedModelINITokenPrefix.count))
            if Self.isAllowedImportedNeuralFileName(rest) {
                return SakuraL10n.tr("general.neuralUpscaleDL.x2Tile128.title")
            }
            return rest
        }
        if token.hasPrefix(legacyImportedModelINITokenPrefix) {
            let rest = String(token.dropFirst(legacyImportedModelINITokenPrefix.count))
            if Self.isAllowedImportedNeuralFileName(rest) {
                return SakuraL10n.tr("general.neuralUpscaleDL.x2Tile128.title")
            }
            return rest
        }
        return token
    }

    static func modelPickerOptions() -> [(iniValue: String, label: String)] {
        var opts: [(iniValue: String, label: String)] = [(iniValue: bundledINIValue, label: bundledDisplayLabel())]
        for url in importedNeuralModelURLs() {
            let name = url.lastPathComponent
            guard Self.isAllowedImportedNeuralFileName(name) else { continue }
            opts.append((iniValue: iniTokenForImportedNeuralFile(name: name), label: Self.displayLabel(forINIToken: iniTokenForImportedNeuralFile(name: name))))
        }
        return opts
    }

    private static func sharedAssetsGitHubContentsURL(neuralFolderName: String) -> URL {
        URL(string: "https://api.github.com/repos/MuffinFluffin/Shared-Assets/contents/neural/\(neuralFolderName)?ref=main")!
    }

    static var neuralUpscaleFetchableModels: [NeuralUpscaleFetchableModel] {
        [
            NeuralUpscaleFetchableModel(
                id: "general.neuralUpscaleDL.x2Tile128",
                title: SakuraL10n.tr("general.neuralUpscaleDL.x2Tile128.title"),
                subtitle: SakuraL10n.tr("general.neuralUpscaleDL.x2Tile128.subtitle"),
                sourceURL: sharedAssetsGitHubContentsURL(neuralFolderName: "Sakura-x2-tile128.mlpackage"),
                installKind: .mlpackageGitHubContents
            ),
        ]
    }

    private static func migrateLegacyImportedModelsFolderIfNeeded(docs: URL) {
        let fm = FileManager.default
        let legacy = docs.appendingPathComponent(legacyImportedModelsFolderName, isDirectory: true)
        let current = docs.appendingPathComponent(importedNeuralModelsFolderName, isDirectory: true)
        var legacyIsDir: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &legacyIsDir), legacyIsDir.boolValue else { return }
        if fm.fileExists(atPath: current.path) { return }
        try? fm.moveItem(at: legacy, to: current)
    }

    private static func pruneLegacyImportsIfPresent() {
        let docs = URL(fileURLWithPath: SakuraBridge.documentsDirectory(), isDirectory: true)
        let legacy = docs.appendingPathComponent(legacyImportsFolderName, isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue {
            try? fm.removeItem(at: legacy)
        }
    }
}
