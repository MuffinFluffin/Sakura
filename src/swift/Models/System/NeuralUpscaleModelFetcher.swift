// SPDX-License-Identifier: GPL-3.0+

import Foundation
import zlib

private enum NeuralZipExtract {
    private static let eocdSig: UInt32 = 0x06054b50
    private static let centralSig: UInt32 = 0x02014b50
    private static let localSig: UInt32 = 0x04034b50

    static func unzipAll(from zipURL: URL, to destRoot: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
        let fh = try FileHandle(forReadingFrom: zipURL)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        try fh.seek(toOffset: 0)

        guard fileSize >= 22 else {
            throw NSError(domain: "NeuralZip", code: 1, userInfo: [NSLocalizedDescriptionKey: "Zip too small"])
        }

        let scanLen = min(fileSize, UInt64(65535 + 22))
        try fh.seek(toOffset: fileSize - scanLen)
        let tailData = fh.readData(ofLength: Int(scanLen))
        guard let eocdIdx = Self.findEOCD(in: tailData) else {
            throw NSError(domain: "NeuralZip", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing zip directory"])
        }
        let centralOffset = Int(Self.readUInt32(tailData, eocdIdx + 16))
        let diskEntries = Int(Self.readUInt16(tailData, eocdIdx + 10))

        var off = centralOffset
        for _ in 0..<diskEntries {
            let hdr = try Self.readCentralHeader(fh: fh, startOffset: UInt64(off))
            if hdr.signature != centralSig { break }
            let nameData = try Self.readBytes(fh: fh, at: hdr.nameStart, count: Int(hdr.fileNameLength))
            guard let nameStr = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .ascii) else {
                off = hdr.nextEntryOffset
                continue
            }
            let norm = nameStr.replacingOccurrences(of: "\\", with: "/")
            if norm.contains("..") || norm.hasPrefix("/") {
                off = hdr.nextEntryOffset
                continue
            }
            if norm.hasSuffix("/") {
                let dirURL = destRoot.appendingPathComponent(norm, isDirectory: true)
                try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                off = hdr.nextEntryOffset
                continue
            }
            let outURL = destRoot.appendingPathComponent(norm)
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.extractLocalFile(
                fh: fh,
                localHeaderOffset: UInt64(hdr.localHeaderOffset),
                method: hdr.compressionMethod,
                compressedSize: hdr.compressedSize,
                uncompressedSize: hdr.uncompressedSize,
                expectedNameLen: hdr.fileNameLength,
                outputURL: outURL
            )
            off = hdr.nextEntryOffset
        }
    }

    private struct CentralParsed {
        let signature: UInt32
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let fileNameLength: UInt16
        let extraLength: UInt16
        let commentLength: UInt16
        let localHeaderOffset: UInt32
        let nameStart: UInt64
        let nextEntryOffset: Int
    }

    private static func findEOCD(in data: Data) -> Int? {
        let n = data.count
        if n < 22 { return nil }
        for i in stride(from: n - 22, through: 0, by: -1) {
            if Self.readUInt32(data, i) == eocdSig { return i }
        }
        return nil
    }

    private static func readCentralHeader(fh: FileHandle, startOffset: UInt64) throws -> CentralParsed {
        try fh.seek(toOffset: startOffset)
        let fixed = fh.readData(ofLength: 46)
        guard fixed.count == 46 else {
            throw NSError(domain: "NeuralZip", code: 3, userInfo: [NSLocalizedDescriptionKey: "Truncated central header"])
        }
        let sig = Self.readUInt32(fixed, 0)
        let method = Self.readUInt16(fixed, 10)
        let csize = Self.readUInt32(fixed, 20)
        let usize = Self.readUInt32(fixed, 24)
        let nameLen = Self.readUInt16(fixed, 28)
        let extraLen = Self.readUInt16(fixed, 30)
        let commentLen = Self.readUInt16(fixed, 32)
        let localOff = Self.readUInt32(fixed, 42)
        let nameStart = startOffset + 46
        let entryTotal = 46 + Int(nameLen) + Int(extraLen) + Int(commentLen)
        let startInt = Int(startOffset)
        return CentralParsed(
            signature: sig,
            compressionMethod: method,
            compressedSize: csize,
            uncompressedSize: usize,
            fileNameLength: nameLen,
            extraLength: extraLen,
            commentLength: commentLen,
            localHeaderOffset: localOff,
            nameStart: nameStart,
            nextEntryOffset: startInt + entryTotal
        )
    }

    private static func extractLocalFile(
        fh: FileHandle,
        localHeaderOffset: UInt64,
        method: UInt16,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        expectedNameLen: UInt16,
        outputURL: URL
    ) throws {
        try fh.seek(toOffset: localHeaderOffset)
        let head = fh.readData(ofLength: 30)
        guard head.count == 30, Self.readUInt32(head, 0) == localSig else {
            throw NSError(domain: "NeuralZip", code: 4, userInfo: [NSLocalizedDescriptionKey: "Bad local header"])
        }
        let nameLen = Self.readUInt16(head, 26)
        let extraLen = Self.readUInt16(head, 28)
        guard nameLen == expectedNameLen else {
            throw NSError(domain: "NeuralZip", code: 5, userInfo: [NSLocalizedDescriptionKey: "Zip name mismatch"])
        }
        let skip = localHeaderOffset + 30 + UInt64(nameLen) + UInt64(extraLen)
        try fh.seek(toOffset: skip)
        let compData = fh.readData(ofLength: Int(compressedSize))
        guard compData.count == Int(compressedSize) else {
            throw NSError(domain: "NeuralZip", code: 6, userInfo: [NSLocalizedDescriptionKey: "Truncated zip data"])
        }
        if method == 0 {
            if UInt32(compData.count) != uncompressedSize {
                throw NSError(domain: "NeuralZip", code: 7, userInfo: [NSLocalizedDescriptionKey: "Stored size mismatch"])
            }
            try compData.write(to: outputURL, options: .atomic)
        } else if method == 8 {
            let inflated = try inflateRawDeflate(compData, expectedOut: Int(uncompressedSize))
            try inflated.write(to: outputURL, options: .atomic)
        } else {
            throw NSError(domain: "NeuralZip", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unsupported zip compression"])
        }
    }

    private static func inflateRawDeflate(_ src: Data, expectedOut: Int) throws -> Data {
        if src.isEmpty {
            guard expectedOut == 0 else {
                throw NSError(domain: "NeuralZip", code: 9, userInfo: [NSLocalizedDescriptionKey: "Empty deflate payload"])
            }
            return Data()
        }
        var strm = z_stream()
        strm.zalloc = nil
        strm.zfree = nil
        strm.opaque = nil
        guard inflateInit2_(&strm, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw NSError(domain: "NeuralZip", code: 9, userInfo: [NSLocalizedDescriptionKey: "zlib init failed"])
        }
        defer { inflateEnd(&strm) }

        var output = Data()
        output.reserveCapacity(max(expectedOut, Int(Double(src.count) * 2.5)))

        try src.withUnsafeBytes { (rawIn: UnsafeRawBufferPointer) in
            guard let inBase = rawIn.bindMemory(to: UInt8.self).baseAddress else { return }
            strm.next_in = UnsafeMutablePointer(mutating: inBase)
            strm.avail_in = UInt32(src.count)

            var window = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let ret: Int32 = window.withUnsafeMutableBufferPointer { buf in
                    guard let outBase = buf.baseAddress else { return Z_STREAM_ERROR }
                    strm.next_out = outBase
                    strm.avail_out = UInt32(buf.count)
                    return inflate(&strm, Z_FINISH)
                }
                let have = window.count - Int(strm.avail_out)
                if have > 0 {
                    output.append(contentsOf: window[0..<have])
                }
                if ret == Z_STREAM_END {
                    break
                }
                if strm.avail_out == 0 {
                    continue
                }
                if ret != Z_OK && ret != Z_BUF_ERROR {
                    throw NSError(domain: "NeuralZip", code: 11, userInfo: [NSLocalizedDescriptionKey: "Inflate failed (\(ret))"])
                }
            }
        }

        if expectedOut > 0, output.count != expectedOut {
            throw NSError(domain: "NeuralZip", code: 12, userInfo: [NSLocalizedDescriptionKey: "Inflate size mismatch"])
        }
        return output
    }

    private static func readBytes(fh: FileHandle, at: UInt64, count: Int) throws -> Data {
        try fh.seek(toOffset: at)
        let d = fh.readData(ofLength: count)
        guard d.count == count else {
            throw NSError(domain: "NeuralZip", code: 12, userInfo: [NSLocalizedDescriptionKey: "Read failed"])
        }
        return d
    }

    private static func readUInt16(_ data: Data, _ o: Int) -> UInt16 {
        guard o + 2 <= data.count else { return 0 }
        return UInt16(data[o]) | UInt16(data[o + 1]) << 8
    }

    private static func readUInt32(_ data: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= data.count else { return 0 }
        return UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
    }
}

private struct NeuralGitHubJSONErrorPayload: Decodable {
    let message: String?
}

private struct NeuralGitHubContentEntry: Decodable {
    let type: String
    let path: String
    let url: String
    let downloadURL: String?

    enum CodingKeys: String, CodingKey {
        case type, path, url
        case downloadURL = "download_url"
    }
}

@Observable
@MainActor
final class NeuralUpscaleModelFetcher {
    static let shared = NeuralUpscaleModelFetcher()

    private init() {}

    var activeID: String?
    var alertMessage: String?
    var showAlert = false

    func tileSubtitle(for id: String, idle: String) -> String {
        activeID == id ? SakuraL10n.tr("general.neuralDownload.downloading") : idle
    }

    func download(_ item: NeuralUpscaleFetchableModel) {
        guard activeID == nil else { return }
        activeID = item.id
        Task {
            await runDownload(item)
        }
    }

    private func runDownload(_ item: NeuralUpscaleFetchableModel) async {
        defer { activeID = nil }
        do {
            let name = try await Self.performInstall(item)
            alertMessage = "Installed \(name) in Documents/\(NeuralUpscaleRegistry.importedNeuralModelsFolderName)/"
            showAlert = true
            SakuraBridge.applyEmulatorSettingsImmediately()
            SFXManager.shared.play(.confirm)
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
            SakuraLogUnified("NeuralDownload", "Warning", "\(error.localizedDescription)")
        }
    }

    private nonisolated static func performInstall(_ item: NeuralUpscaleFetchableModel) async throws -> String {
        guard let destParent = NeuralUpscaleRegistry.importedNeuralModelsDirectoryURL() else {
            throw NSError(domain: "NeuralDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open model folder"])
        }

        switch item.installKind {
        case .mlpackageGitHubContents:
            return try await Self.performInstallGitHubMlpackageTree(item.sourceURL, destParent: destParent)
        case .mlmodel, .mlpackageZip:
            break
        }

        let req = Self.urlRequestCDNBlob(from: item.sourceURL)
        let (downloadTmp, response) = try await URLSession.shared.download(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "NeuralDownload", code: 5, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "NeuralDownload",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Download failed (\(http.statusCode))"])
        }
        let fm = FileManager.default
        let sessionScratch = fm.temporaryDirectory.appendingPathComponent("sakura-neural-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sessionScratch, withIntermediateDirectories: true)
        let dlFile = sessionScratch.appendingPathComponent("dl.bin")
        try? fm.removeItem(at: dlFile)
        try fm.moveItem(at: downloadTmp, to: dlFile)
        defer {
            try? fm.removeItem(at: sessionScratch)
        }

        switch item.installKind {
        case .mlmodel(let fileName):
            let dest = destParent.appendingPathComponent(fileName)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: dlFile, to: dest)
            return fileName
        case .mlpackageZip(let preferSub):
            let unzipDir = sessionScratch.appendingPathComponent("unzipped", isDirectory: true)
            try Self.validateProbablyZip(dlFile)
            try NeuralZipExtract.unzipAll(from: dlFile, to: unzipDir)
            let installed = try Self.installTree(from: unzipDir, into: destParent, fm: fm, preferMlpackagePathSubstring: preferSub)
            return installed.lastPathComponent
        case .mlpackageGitHubContents:
            preconditionFailure()
        }
    }

    private nonisolated static func urlRequestCDNBlob(from url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        return req
    }

    private nonisolated static func urlRequestGitHubREST(from url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Sakura-iOS NeuralDownload", forHTTPHeaderField: "User-Agent")
        return req
    }

    private nonisolated static func githubBundleRepoPrefix(contentsAPIRoot: URL) throws -> String {
        guard let comps = URLComponents(url: contentsAPIRoot, resolvingAgainstBaseURL: false),
              comps.host == "api.github.com" else {
            throw NSError(
                domain: "NeuralDownload",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "GitHub Contents URL expected (api.github.com)"])
        }
        var path = comps.path
        while path.last == "/" {
            path.removeLast()
        }
        let decoded = path.removingPercentEncoding ?? path
        let needle = "/contents/"
        guard let range = decoded.range(of: needle) else {
            throw NSError(
                domain: "NeuralDownload",
                code: 11,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "GitHub URL missing /repos/OWNER/REPO/contents/<path>",
                ])
        }
        let tail = decoded[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !tail.isEmpty else {
            throw NSError(domain: "NeuralDownload", code: 11, userInfo: [NSLocalizedDescriptionKey: "Empty GitHub contents path"])
        }
        return tail
    }

    private nonisolated static func relativeRepoPathInsideBundle(fullPath: String, bundleRepoPrefix: String) throws -> String {
        if fullPath == bundleRepoPrefix { return "." }
        guard fullPath.hasPrefix(bundleRepoPrefix + "/") else {
            throw NSError(
                domain: "NeuralDownload",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected path \(fullPath)"])
        }
        let offset = bundleRepoPrefix.count + 1
        let inner = String(fullPath.dropFirst(offset))
        guard !inner.isEmpty else {
            throw NSError(domain: "NeuralDownload", code: 12, userInfo: [NSLocalizedDescriptionKey: "Empty inner path"])
        }
        try assertNoPathTraversal(inner)
        return inner
    }

    private nonisolated static func assertNoPathTraversal(_ relativePiece: String) throws {
        for seg in relativePiece.split(separator: "/", omittingEmptySubsequences: true) where seg != "." {
            if seg == ".."
                || seg.contains(":") {
                throw NSError(
                    domain: "NeuralDownload",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Unsafe path fragment in model tree"])
            }
        }
    }

    private nonisolated static func githubParsedDirectory(contentsAPIURL: URL) async throws -> [NeuralGitHubContentEntry] {
        let req = Self.urlRequestGitHubREST(from: contentsAPIURL)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "NeuralDownload", code: 14, userInfo: [NSLocalizedDescriptionKey: "No GitHub HTTP response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let msg =
                ((try? JSONDecoder().decode(NeuralGitHubJSONErrorPayload.self, from: data))?.message)
                ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "NeuralDownload", code: 15, userInfo: [NSLocalizedDescriptionKey: "GitHub: \(msg)"])
        }
        let decoder = JSONDecoder()
        if let lone = try? decoder.decode(NeuralGitHubContentEntry.self, from: data),
           lone.type == "file" {
            throw NSError(
                domain: "NeuralDownload",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "URL points at a single file—the app needs the .mlpackage directory"])
        }
        return try decoder.decode([NeuralGitHubContentEntry].self, from: data)
    }

    private nonisolated static func downloadGitHubBlobToFile(downloadURLStr: String, destFile: URL, fm: FileManager) async throws {
        guard let dlURL = URL(string: downloadURLStr) else {
            throw NSError(domain: "NeuralDownload", code: 17, userInfo: [NSLocalizedDescriptionKey: "Bad download URL"])
        }
        let req = Self.urlRequestCDNBlob(from: dlURL)
        try fm.createDirectory(at: destFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (tmpDL, resp) = try await URLSession.shared.download(for: req)
        guard let gh = resp as? HTTPURLResponse, (200...299).contains(gh.statusCode) else {
            let sc = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "NeuralDownload",
                code: 18,
                userInfo: [NSLocalizedDescriptionKey: "Blob download failed (\(sc))"])
        }
        if fm.fileExists(atPath: destFile.path) {
            try fm.removeItem(at: destFile)
        }
        try fm.moveItem(at: tmpDL, to: destFile)
    }

    private nonisolated static func downloadGithubMlpackageRecursive(
        contentsAPIURL: URL,
        bundleRepoPrefix: String,
        packageRootStaging: URL,
        fm: FileManager
    ) async throws {
        let entries = try await Self.githubParsedDirectory(contentsAPIURL: contentsAPIURL)
        for entry in entries {
            switch entry.type {
            case "dir":
                guard let sub = URL(string: entry.url) else { continue }
                try await Self.downloadGithubMlpackageRecursive(
                    contentsAPIURL: sub,
                    bundleRepoPrefix: bundleRepoPrefix,
                    packageRootStaging: packageRootStaging,
                    fm: fm)
            case "file":
                let relPiece = try Self.relativeRepoPathInsideBundle(fullPath: entry.path, bundleRepoPrefix: bundleRepoPrefix)
                guard relPiece != "." else { continue }
                guard let dup = entry.downloadURL, !dup.isEmpty else {
                    throw NSError(
                        domain: "NeuralDownload",
                        code: 19,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Missing download_url on \(entry.path)",
                        ])
                }
                var outURL = packageRootStaging
                for comp in relPiece.split(separator: "/", omittingEmptySubsequences: true) {
                    outURL.appendPathComponent(String(comp))
                }
                try await Self.downloadGitHubBlobToFile(downloadURLStr: dup, destFile: outURL, fm: fm)
            default:
                continue
            }
        }
    }

    private nonisolated static func performInstallGitHubMlpackageTree(_ contentsRoot: URL, destParent: URL) async throws -> String {
        let fm = FileManager.default
        let bundlePrefix = try Self.githubBundleRepoPrefix(contentsAPIRoot: contentsRoot)

        guard bundlePrefix.lowercased().split(separator: "/").last?.hasSuffix(".mlpackage") == true else {
            throw NSError(
                domain: "NeuralDownload",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Contents URL must target a folder ending in .mlpackage",
                ])
        }

        let scratch = fm.temporaryDirectory.appendingPathComponent(
            "sakura-neural-gh-\(UUID().uuidString)",
            isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: scratch)
        }

        let folderName: String =
            bundlePrefix.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? bundlePrefix
        guard folderName.lowercased().hasSuffix(".mlpackage") else {
            throw NSError(domain: "NeuralDownload", code: 10, userInfo: [NSLocalizedDescriptionKey: "Malformed .mlpackage path"])
        }

        let staging = scratch.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try await Self.downloadGithubMlpackageRecursive(
            contentsAPIURL: contentsRoot,
            bundleRepoPrefix: bundlePrefix,
            packageRootStaging: staging,
            fm: fm)

        let finalDest = destParent.appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: finalDest.path) {
            try fm.removeItem(at: finalDest)
        }
        try fm.moveItem(at: staging, to: finalDest)
        return folderName
    }

    private nonisolated static func installTree(
        from root: URL,
        into destParent: URL,
        fm: FileManager,
        preferMlpackagePathSubstring: String? = nil
    ) throws -> URL {
        var mlpackages: [URL] = []
        var mlmodels: [URL] = []

        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "NeuralDownload", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unzip read failed"])
        }
        while let u = en.nextObject() as? URL {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = u.lastPathComponent.lowercased()
            if name.hasSuffix(".mlpackage"), isDir {
                mlpackages.append(u)
            } else if name.hasSuffix(".mlmodel"), !isDir {
                mlmodels.append(u)
            }
        }

        if let pref = preferMlpackagePathSubstring, !pref.isEmpty {
            let filtered = mlpackages.filter { $0.path.contains(pref) }
            if filtered.isEmpty {
                throw NSError(
                    domain: "NeuralDownload",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Archive had no .mlpackage path containing \(pref)"
                    ])
            }
            mlpackages = filtered
        }

        if let pkg = mlpackages.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }).first {
            let dest = destParent.appendingPathComponent(pkg.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: pkg, to: dest)
            return dest
        }
        if let m = mlmodels.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }).first {
            let dest = destParent.appendingPathComponent(m.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: m, to: dest)
            return dest
        }
        throw NSError(domain: "NeuralDownload", code: 3, userInfo: [NSLocalizedDescriptionKey: "Archive had no .mlpackage or .mlmodel"])
    }

    /// Hugging Face / proxies sometimes serve HTML stubs; zip path must begin with PK.
    private nonisolated static func validateProbablyZip(_ file: URL) throws {
        let fh = try FileHandle(forReadingFrom: file)
        defer {
            try? fh.close()
        }
        guard let prefix = try fh.read(upToCount: 4), prefix.count >= 4 else {
            throw NSError(domain: "NeuralDownload", code: 7, userInfo: [NSLocalizedDescriptionKey: "Download too short for ZIP"])
        }
        if prefix[0] == 0x50, prefix[1] == 0x4B, prefix[2] == 0x03, prefix[3] == 0x04 {
            return
        }
        throw NSError(
            domain: "NeuralDownload",
            code: 8,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "File is not a zip (CDN page or stale link)—nothing to unzip"
            ])
    }
}
