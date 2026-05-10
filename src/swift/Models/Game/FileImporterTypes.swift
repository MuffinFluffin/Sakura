import Foundation
import UniformTypeIdentifiers

enum FileImporterTypes {
    private static let gameFilenameExtensionsLibrary: [String] = [
        "iso", "bin", "cue", "cua", "chd", "img", "pbp", "m3u",
        "toc", "ccd", "sub", "mds", "mdf", "nrg", "cdi",
        "psx", "ecm", "cso", "zso", "gz",
        "scph", "rom", "nvm", "mec",
    ]

    private static let additionalSettingsExtensions: [String] = ["elf"]

    static let libraryGameImports: [UTType] = {
        var types = gameFilenameExtensionsLibrary.compactMap { UTType(filenameExtension: $0) }
        types.append(.folder)
        return types.isEmpty ? [.data] : types
    }()

    static let settingsGameImports: [UTType] = {
        let exts = gameFilenameExtensionsLibrary + additionalSettingsExtensions
        var types = exts.compactMap { UTType(filenameExtension: $0) }
        types.append(.folder)
        return types.isEmpty ? [.data] : types
    }()

    static let coverArtImports: [UTType] = {
        var types: [UTType] = [.image, .png, .jpeg]
        if let w = UTType(filenameExtension: "webp") { types.append(w) }
        return types
    }()
}
