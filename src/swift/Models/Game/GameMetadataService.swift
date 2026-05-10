// GameMetadataService.swift: download and cache game covers and Wikipedia info
// SPDX-License-Identifier: GPL-3.0+

import Foundation
import UIKit

/// Metadata that can be extracted from a Wikipedia article summary.
/// Plain-old `Codable` value so it round-trips through JSON on disk.
struct GameInfo: Codable, Equatable, Sendable {
    var title: String
    var releaseDate: String
    var genre: String
    var developer: String
    var publisher: String
    var summary: String
    var sourceURL: String

    static let unknown = GameInfo(
        title: "",
        releaseDate: "Unknown",
        genre: "Unknown",
        developer: "Unknown",
        publisher: "Unknown",
        summary: "",
        sourceURL: ""
    )
}

final class GameMetadataService: @unchecked Sendable {
    static let shared = GameMetadataService()

    /// Root folder for every piece of game-level data we generate at runtime.
    /// Lives next to `bios/` / `Games/` / `logs/` under Documents.
    let metadataDir: URL
    let coversDir: URL
    let infoDir: URL

    private var inFlightCoverTasks: [String: URLSessionDataTask] = [:]
    private var inFlightCoverKeys: Set<String> = []
    private var inFlightInfoTasks: Set<String> = []
    private var coverGameDB: [CoverGameDBEntry]?
    private var coverGameDBLoading = false
    private var coverGameDBWaiters: [([CoverGameDBEntry]) -> Void] = []
    private let queue = DispatchQueue(label: "sakura.metadata.queue")

    private struct CoverCandidate {
        let url: URL
        let fileExtension: String
    }

    private struct CoverGameDBEntry: Decodable {
        let name: String
        let codes: [String]
    }

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        metadataDir = docs.appendingPathComponent("metadata", isDirectory: true)
        coversDir = metadataDir.appendingPathComponent("covers", isDirectory: true)
        infoDir = metadataDir.appendingPathComponent("info", isDirectory: true)

        let fm = FileManager.default
        try? fm.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: coversDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: infoDir, withIntermediateDirectories: true)

        // One-time migration: older builds stored covers in Documents/covers/.
        // Move any surviving files into the new home so users don't re-download.
        let legacyCovers = docs.appendingPathComponent("covers", isDirectory: true)
        if fm.fileExists(atPath: legacyCovers.path) {
            if let entries = try? fm.contentsOfDirectory(atPath: legacyCovers.path) {
                for name in entries {
                    let src = legacyCovers.appendingPathComponent(name)
                    let dst = coversDir.appendingPathComponent(name)
                    if !fm.fileExists(atPath: dst.path) {
                        try? fm.moveItem(at: src, to: dst)
                    }
                }
            }
            // Remove the old folder if it's now empty.
            if let remaining = try? fm.contentsOfDirectory(atPath: legacyCovers.path), remaining.isEmpty {
                try? fm.removeItem(at: legacyCovers)
            }
        }

        // One-shot migration: wipe any all-Unknown cache entries left behind
        // by the old codepath that cached failures permanently. Without this
        // every existing install would have to wait 24h for the new expiry
        // rule in cachedInfo to kick in per-title. on a full library
        // that's a lot of games stuck on "Unknown / Unknown / Unknown".
        // Gated on a UserDefaults key so we only pay the directory walk once.
        let migrationKey = "sakura.metadata.wipedUnknownCache.v1"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            if let entries = try? fm.contentsOfDirectory(atPath: infoDir.path) {
                for name in entries where name.hasSuffix(".json") {
                    let url = infoDir.appendingPathComponent(name)
                    guard let data = try? Data(contentsOf: url),
                          let info = try? JSONDecoder().decode(GameInfo.self, from: data)
                    else { continue }
                    if Self.isAllUnknown(info) {
                        try? fm.removeItem(at: url)
                    }
                }
            }
            UserDefaults.standard.set(true, forKey: migrationKey)
        }

        let migrateInfoKey = "sakura.metadata.infoLangSubdir.v1"
        if !UserDefaults.standard.bool(forKey: migrateInfoKey) {
            let enSub = infoDir.appendingPathComponent("en", isDirectory: true)
            try? fm.createDirectory(at: enSub, withIntermediateDirectories: true)
            if let entries = try? fm.contentsOfDirectory(atPath: infoDir.path) {
                for name in entries where name.hasSuffix(".json") {
                    let src = infoDir.appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                    let dst = enSub.appendingPathComponent(name)
                    if !fm.fileExists(atPath: dst.path) {
                        try? fm.moveItem(at: src, to: dst)
                    }
                }
            }
            UserDefaults.standard.set(true, forKey: migrateInfoKey)
        }
    }

    private static func wikipediaLanguageCodeForRequest() -> String {
        let raw = UserDefaults.standard.string(forKey: AppLocale.appStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty {
            let lang = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
            return canonicalWikipediaLanguage(lang)
        }
        return canonicalWikipediaLanguage(raw)
    }

    private static func canonicalWikipediaLanguage(_ id: String) -> String {
        let lower = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("zh") { return "zh" }
        let base = lower.split(separator: "-").first.map(String.init) ?? lower
        switch base {
        case "ja", "en", "es", "fr", "de", "pt", "ru", "it", "ko", "nl", "pl", "tr", "vi", "id", "th", "ar", "hi":
            return base
        default:
            return "en"
        }
    }

    private static func wikipediaLanguageFallbackChain() -> [String] {
        let p = wikipediaLanguageCodeForRequest()
        if p == "en" { return ["en"] }
        var chain = [p]
        if !chain.contains("en") { chain.append("en") }
        return chain
    }

    private static func infoFetchFlightKey(forCacheKey key: String) -> String {
        "\(key)|\(wikipediaLanguageCodeForRequest())"
    }

    private static func wikipediaHost(forWikiLang wikiLang: String) -> String {
        "\(wikiLang).wikipedia.org"
    }

    private static func wikipediaRESTSummaryURL(for title: String, wikiLang: String) -> URL? {
        let slug = title
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        return URL(string: "https://\(wikipediaHost(forWikiLang: wikiLang))/api/rest_v1/page/summary/\(slug)")
    }

    private func infoDiskURL(forCacheKey key: String) -> URL {
        let lang = Self.wikipediaLanguageCodeForRequest()
        let sub = infoDir.appendingPathComponent(lang, isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub.appendingPathComponent("\(key).json")
    }

    // MARK: - Covers

    /// Returns a cached cover path if it already exists on disk.
    func cachedCoverPath(forSerial serial: String) -> String? {
        let safeSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeSerial.isEmpty else { return nil }
        for ext in ["jpg", "jpeg", "png", "webp"] {
            let url = coversDir.appendingPathComponent("\(safeSerial).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                // non-blocking: kicks upscale if enabled and not already cached
                GameCoverUpscaler.shared.upscaleIfNeeded(originalCoverPath: url.path, serial: safeSerial)
                return url.path
            }
        }
        return nil
    }

    func removeCachedSidecarsForLibraryListing(metadataKey: String, discSerial: String?) {
        let fm = FileManager.default
        var keys: Set<String> = []
        let mk = metadataKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mk.isEmpty { keys.insert(mk) }
        if let s = discSerial?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            keys.insert(s)
        }
        for k in keys {
            for ext in ["jpg", "jpeg", "png", "webp"] {
                try? fm.removeItem(at: coversDir.appendingPathComponent("\(k).\(ext)"))
            }
            try? fm.removeItem(at: coversDir.appendingPathComponent("\(k).up.png"))
            try? fm.removeItem(at: infoDiskURL(forCacheKey: k))
            try? fm.removeItem(at: infoDir.appendingPathComponent("\(k).json"))
            guard let subs = try? fm.contentsOfDirectory(
                at: infoDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for sub in subs {
                let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                try? fm.removeItem(at: sub.appendingPathComponent("\(k).json"))
            }
        }
    }

    /// Returns the GAN-upscaled sibling (`<base>.up.png`) if it exists, otherwise nil.
    func cachedUpscaledCoverPath(forSerial serial: String) -> String? {
        let safeSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeSerial.isEmpty else { return nil }
        guard let original = cachedCoverPathRaw(forSerial: safeSerial) else { return nil }
        return GameCoverUpscaler.shared.upscaledSiblingPath(forOriginal: original)
    }

    // same as cachedCoverPath but without kicking the upscale side effect.
    // used internally when we just need a path and don't want the feedback loop.
    private func cachedCoverPathRaw(forSerial serial: String) -> String? {
        for ext in ["jpg", "jpeg", "png", "webp"] {
            let url = coversDir.appendingPathComponent("\(serial).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }

    /// Asynchronously fetch the cover from xlenore/psx-covers (serial-based, no API key).
    /// Calls `completion` on the main thread with the local file path, or nil on failure.
    func fetchCover(forSerial serial: String, completion: @Sendable @escaping (String?) -> Void) {
        let safeSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeSerial.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }

            // Already cached?
            if let cached = self.cachedCoverPath(forSerial: safeSerial) {
                DispatchQueue.main.async { completion(cached) }
                return
            }

            guard self.inFlightCoverKeys.insert(safeSerial).inserted else { return }

            let candidates = Self.coverCandidates(forSerial: safeSerial)
            guard !candidates.isEmpty else {
                self.inFlightCoverKeys.remove(safeSerial)
                DispatchQueue.main.async { completion(nil) }
                return
            }

            self.fetchCoverCandidate(taskKey: safeSerial, cacheKey: safeSerial, candidates: candidates, index: 0, completion: completion)
        }
    }

    /// Fallback for compressed/odd disc formats where we can't scan a serial.
    // uses xlenore's title-to-serial db, then saves the art under cacheKey.
    func fetchCover(forCacheKey cacheKey: String, title: String, completion: @Sendable @escaping (String?) -> Void) {
        let safeKey = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = Self.normalizeTitleForLookup(title)
        guard !safeKey.isEmpty, !cleanTitle.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }

            if let cached = self.cachedCoverPath(forSerial: safeKey) {
                DispatchQueue.main.async { completion(cached) }
                return
            }
            guard self.inFlightCoverKeys.insert(safeKey).inserted else { return }

            self.loadCoverGameDB { [weak self] entries in
                guard let self = self else { return }
                let codes = Self.coverSerials(forTitle: cleanTitle, entries: entries)
                let candidates = codes.flatMap { Self.coverCandidates(forSerial: $0) }
                guard !candidates.isEmpty else {
                    self.queue.async { [weak self] in
                        self?.inFlightCoverKeys.remove(safeKey)
                    }
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                self.fetchCoverCandidate(taskKey: safeKey, cacheKey: safeKey, candidates: candidates, index: 0, completion: completion)
            }
        }
    }

    func cancelFetch(forSerial serial: String) {
        let safeSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async { [weak self] in
            self?.inFlightCoverTasks[safeSerial]?.cancel()
            self?.inFlightCoverTasks.removeValue(forKey: safeSerial)
            self?.inFlightCoverKeys.remove(safeSerial)
        }
    }

    private static func coverCandidates(forSerial serial: String) -> [CoverCandidate] {
        let serialEncoded = serial.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serial
        let rawBase = "https://raw.githubusercontent.com/xlenore/psx-covers/main/covers"
        return [
            URL(string: "\(rawBase)/default/\(serialEncoded).jpg").map { CoverCandidate(url: $0, fileExtension: "jpg") },
            URL(string: "\(rawBase)/3d/\(serialEncoded).png").map { CoverCandidate(url: $0, fileExtension: "png") },
        ].compactMap { $0 }
    }

    private func fetchCoverCandidate(
        taskKey: String,
        cacheKey: String,
        candidates: [CoverCandidate],
        index: Int,
        completion: @Sendable @escaping (String?) -> Void
    ) {
        guard index < candidates.count else {
            queue.async { [weak self] in
                self?.inFlightCoverTasks.removeValue(forKey: taskKey)
                self?.inFlightCoverKeys.remove(taskKey)
            }
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let candidate = candidates[index]
        let task = URLSession.shared.dataTask(with: candidate.url) { [weak self] data, response, error in
            guard let self = self else { return }
            guard let data,
                  error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = UIImage(data: data) else {
                self.fetchCoverCandidate(taskKey: taskKey, cacheKey: cacheKey, candidates: candidates, index: index + 1, completion: completion)
                return
            }

            let ext = httpResponse.mimeType?.contains("png") == true ? "png" : candidate.fileExtension
            let fileURL = self.coversDir.appendingPathComponent("\(cacheKey).\(ext)")

            do {
                if ext == "png" {
                    try data.write(to: fileURL)
                } else {
                    guard let jpegData = image.jpegData(compressionQuality: 0.95) else {
                        self.fetchCoverCandidate(taskKey: taskKey, cacheKey: cacheKey, candidates: candidates, index: index + 1, completion: completion)
                        return
                    }
                    try jpegData.write(to: fileURL)
                }
                self.queue.async { [weak self] in
                    self?.inFlightCoverTasks.removeValue(forKey: taskKey)
                    self?.inFlightCoverKeys.remove(taskKey)
                }
                GameCoverUpscaler.shared.upscaleIfNeeded(originalCoverPath: fileURL.path, serial: cacheKey)
                DispatchQueue.main.async { completion(fileURL.path) }
            } catch {
                self.fetchCoverCandidate(taskKey: taskKey, cacheKey: cacheKey, candidates: candidates, index: index + 1, completion: completion)
            }
        }

        queue.async { [weak self] in
            self?.inFlightCoverTasks[taskKey] = task
        }
        task.resume()
    }

    private func loadCoverGameDB(completion: @escaping ([CoverGameDBEntry]) -> Void) {
        if let coverGameDB {
            completion(coverGameDB)
            return
        }
        coverGameDBWaiters.append(completion)
        guard !coverGameDBLoading else { return }
        coverGameDBLoading = true

        let url = URL(string: "https://raw.githubusercontent.com/xlenore/psx-covers/main/tools/gamedb.json")!
        var request = URLRequest(url: url)
        request.setValue("Sakura/1.0 (https://github.com; PlayStation emulator)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let entries: [CoverGameDBEntry]
            if let data,
               let http = response as? HTTPURLResponse,
               http.statusCode == 200,
               let decoded = try? JSONDecoder().decode([CoverGameDBEntry].self, from: data) {
                entries = decoded
            } else {
                entries = []
            }

            self?.queue.async { [weak self] in
                guard let self = self else { return }
                self.coverGameDB = entries
                self.coverGameDBLoading = false
                let waiters = self.coverGameDBWaiters
                self.coverGameDBWaiters.removeAll()
                for waiter in waiters {
                    waiter(entries)
                }
            }
        }
        .resume()
    }

    private static func coverSerials(forTitle title: String, entries: [CoverGameDBEntry]) -> [String] {
        let wanted = normalizedCoverLookupTitle(title)
        guard !wanted.isEmpty else { return [] }

        var scored: [(score: Int, entry: CoverGameDBEntry)] = []
        for entry in entries {
            let candidate = normalizedCoverLookupTitle(entry.name)
            guard !candidate.isEmpty else { continue }
            var score = 0
            if candidate == wanted {
                score += 100
            } else if candidate.hasPrefix(wanted + " ") {
                score += 75
            } else if candidate.contains(wanted) || wanted.contains(candidate) {
                score += 40
            }
            guard score > 0 else { continue }
            let lower = entry.name.lowercased()
            if lower.contains("(usa)") { score += 12 }
            if lower.contains("(europe)") { score += 8 }
            if lower.contains("(demo)") || lower.contains("beta") { score -= 25 }
            scored.append((score, entry))
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(8)
            .flatMap { $0.entry.codes }
            .filter { !$0.hasPrefix("HASH-") }
    }

    private static let coverLookupNormalizeNonAlnum = try! NSRegularExpression(pattern: "[^a-z0-9]+", options: [])
    private static let coverLookupStripArticles = try! NSRegularExpression(pattern: "\\b(the|a|an)\\b", options: [])

    private static func normalizedCoverLookupTitle(_ title: String) -> String {
        var s = normalizeTitleForLookup(title).lowercased()
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: "'", with: "")
        s = coverLookupNormalizeNonAlnum.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = coverLookupStripArticles.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        return s.split(separator: " ").joined(separator: " ")
    }

    // MARK: - Game info (Wikipedia-backed, cached as JSON)

    /// Returns cached game info if present on disk, otherwise nil.
    /// Rejects cached entries that still carry raw wikitext residue from older
    /// builds so they get re-fetched with the improved parser. Also rejects
    /// entries where every meaningful field is "Unknown" and the cache is
    /// older than a day. that way a transient network / disambiguation
    /// failure doesn't permanently poison the cache for a title. Without
    /// this check `fetchInfo` would return the cached Unknown record to
    /// every caller forever, which is exactly the "metadata not being
    /// pulled from wiki for all games" bug users keep hitting.
    private func loadValidatedCachedInfo(at url: URL) -> GameInfo? {
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(GameInfo.self, from: data)
        else { return nil }

        let combined = info.releaseDate + info.genre + info.developer + info.publisher
        if combined.contains("{{") || combined.contains("}}") || combined.contains("'''") || combined.contains("[[") {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        if Self.isAllUnknown(info) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
            if Date().timeIntervalSince(mtime) > 24 * 60 * 60 {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        return info
    }

    func cachedInfo(forSerial serial: String) -> GameInfo? {
        let key = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        if let info = loadValidatedCachedInfo(at: infoDiskURL(forCacheKey: key)) {
            return info
        }

        let lang = Self.wikipediaLanguageCodeForRequest()
        if lang == "en" {
            let legacyFlat = infoDir.appendingPathComponent("\(key).json")
            return loadValidatedCachedInfo(at: legacyFlat)
        }
        return nil
    }

    /// True when the record carries no useful infobox data. Title/summary are
    /// ignored on purpose. we only trust the fields a human actually cares
    /// about in the library card.
    private static func isAllUnknown(_ info: GameInfo) -> Bool {
        func blank(_ s: String) -> Bool {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.caseInsensitiveCompare("unknown") == .orderedSame
        }
        return blank(info.releaseDate) && blank(info.genre)
            && blank(info.developer) && blank(info.publisher)
    }

    /// Fetch game info from Wikipedia (summary API + infobox parse) keyed by serial+title.
    /// the serial is only used as a cache key. the lookup uses the title.
    /// Calls `completion` on the main thread.
    func fetchInfo(forSerial serial: String, title: String, completion: @escaping @Sendable (GameInfo?) -> Void) {
        let key = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = Self.normalizeTitleForLookup(title)
        guard !key.isEmpty, !cleanTitle.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }

            if let cached = self.cachedInfo(forSerial: key) {
                DispatchQueue.main.async { completion(cached) }
                return
            }

            let flightKey = Self.infoFetchFlightKey(forCacheKey: key)
            if self.inFlightInfoTasks.contains(flightKey) { return }
            self.inFlightInfoTasks.insert(flightKey)

            self.resolveArticleTitle(forSearch: cleanTitle) { [weak self] resolved in
                guard let self = self else { return }
                guard let articleTitle = resolved else {
                    self.queue.async { [weak self] in
                        self?.inFlightInfoTasks.remove(flightKey)
                    }
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                self.verifyIsVideoGame(title: articleTitle) { [weak self] isGame in
                    guard let self = self else { return }
                    if !isGame {
                        SakuraLogUnified("Metadata", "Dev", "Rejected '\(articleTitle)' for '\(cleanTitle)': article isn't tagged as a video game")
                        self.queue.async { [weak self] in
                            self?.inFlightInfoTasks.remove(flightKey)
                        }
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    self.performFullLookup(flightKey: flightKey, serial: key, articleTitle: articleTitle, completion: completion)
                }
            }
        }
    }

    // MARK: Wikipedia internals

    /// Resolves a game title to the best-matching Wikipedia article title.
    /// Strategy:
    ///   1. Try the REST summary endpoint directly with the provided title.
    ///   2. If that returns a disambiguation page (or 404), chain MediaWiki
    ///      searches: "<title> PlayStation video game", then "<title> ps1".
    ///   3. Rank results by PS1-era year/platform markers so the original
    ///      PlayStation article beats later reboots and ports.
    private func resolveArticleTitle(forSearch title: String, completion: @escaping @Sendable (String?) -> Void) {
        fetchSummaryJSON(title: title) { [weak self] json in
            guard let self = self else { return }
            if let json = json {
                let type = (json["type"] as? String) ?? ""
                let resolved = (json["title"] as? String) ?? title
                if type != "disambiguation" && !resolved.isEmpty {
                    completion(resolved)
                    return
                }
            }
            // Chained search fallbacks. Each step narrows less than the
            // previous one so games with unusual titles (eg. "SSX 3",
            // japanese releases, subtitled entries) still find the right
            // PlayStation article. Previously we stopped after the two scoped searches
            // which left many titles with no metadata. wikipediaSearch
            // with the raw title is the catch-all we were missing, and the
            // subtitle-stripped pass handles "Game: Subtitle" by extracting "Subtitle".
            self.wikipediaSearch(query: "\(title) PlayStation video game") { [weak self] hit in
                guard let self = self else { return }
                if let hit = hit {
                    SakuraLogUnified("Metadata", "Dev", "Resolved '\(title)' to '\(hit)' (PlayStation video game)")
                    completion(hit)
                    return
                }
                self.wikipediaSearch(query: "\(title) ps1") { [weak self] hit2 in
                    guard let self = self else { return }
                    if let hit2 = hit2 {
                        SakuraLogUnified("Metadata", "Dev", "Resolved '\(title)' to '\(hit2)' (PS1 search)")
                        completion(hit2)
                        return
                    }
                    self.wikipediaSearch(query: title) { [weak self] hit3 in
                        guard let self = self else { return }
                        if let hit3 = hit3 {
                            SakuraLogUnified("Metadata", "Dev", "Resolved '\(title)' to '\(hit3)' (plain search)")
                            completion(hit3)
                            return
                        }
                        // Final fallback: drop "Main: Subtitle" prefix and
                        // try subtitle alone. Plenty of spinoffs live under
                        // their subtitle on wikipedia.
                        if let subtitle = Self.subtitleForLookup(title), subtitle != title {
                            self.wikipediaSearch(query: "\(subtitle) video game") { hit4 in
                                if let hit4 = hit4 {
                                    SakuraLogUnified("Metadata", "Dev", "Resolved '\(title)' to '\(hit4)' (subtitle '\(subtitle)')")
                                }
                                completion(hit4)
                            }
                        } else {
                            completion(nil)
                        }
                    }
                }
            }
        }
    }

    /// Returns the substring after the first ":" or " - " in the title, or
    /// nil if there isn't one. Used as a last-ditch search when the full
    /// title can't be resolved.
    private static func subtitleForLookup(_ title: String) -> String? {
        for sep in [":", " - "] {
            if let range = title.range(of: sep) {
                let sub = title[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if sub.count >= 3 { return sub }
            }
        }
        return nil
    }

    private func performFullLookup(flightKey: String, serial: String, articleTitle: String, completion: @escaping @Sendable (GameInfo?) -> Void) {
        fetchSummaryJSON(title: articleTitle) { [weak self] summary in
            guard let self = self else { return }

            let resolvedTitle = (summary?["title"] as? String) ?? articleTitle
            let extract = (summary?["extract"] as? String) ?? ""
            let pageURL =
                ((summary?["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String ?? ""

            self.fetchWikipediaInfobox(title: resolvedTitle, sectionZeroOnly: true) { [weak self] sec0Info in
                guard let self = self else { return }

                let completeSec0 = sec0Info.map { !Self.isAllUnknown($0) } ?? false

                let finish: @Sendable (GameInfo?) -> Void = { [weak self] boxInfo in
                    guard let self = self else { return }
                    defer {
                        self.queue.async { [weak self] in
                            self?.inFlightInfoTasks.remove(flightKey)
                        }
                    }

                    var info = boxInfo ?? sec0Info ?? GameInfo.unknown
                    info.title = resolvedTitle
                    info.summary = extract
                    info.sourceURL = pageURL

                    if !Self.isAllUnknown(info) {
                        self.writeInfo(info, forSerial: serial)
                    } else {
                        SakuraLogUnified("Metadata", "Dev", "'\(resolvedTitle)' returned no infobox fields, skipping cache write so next launch retries")
                    }
                    DispatchQueue.main.async { completion(info) }
                }

                if completeSec0 {
                    finish(sec0Info)
                } else {
                    self.fetchWikipediaInfobox(title: resolvedTitle, sectionZeroOnly: false, completion: finish)
                }
            }
        }
    }

    /// Returns true when the given Wikipedia article is about a video game.
    /// Uses three signals in order of trust:
    ///   1. `description` from Wikidata (e.g. "2005 video game", "action
    ///      game", "platform video game").
    ///   2. extract (first paragraph of the article). looks for explicit
    ///      "video game" / "game for the ..." / "playstation game" phrases.
    ///   3. Presence of PlayStation platform tokens in the
    ///      extract, paired with "game".
    /// only needs ONE signal to pass. wikipedia's short descriptions are
    /// noisy for demo discs, so we fall back to text matching rather than
    /// requiring a perfect tag.
    private func verifyIsVideoGame(title: String, completion: @escaping @Sendable (Bool) -> Void) {
        fetchSummaryJSON(title: title) { json in
            guard let json = json else {
                // if we can't even fetch the summary, assume game. the
                // caller already resolved this via our ranked search so
                // there's a decent prior that it's correct.
                completion(true)
                return
            }

            let descriptionRaw = json["description"] as? String ?? ""
            let description = descriptionRaw.lowercased()
            let extractRaw = json["extract"] as? String ?? ""
            let extract = extractRaw.lowercased()

            if description.contains("game") || Self.descriptionSuggestsVideoGame(descriptionRaw) { completion(true); return }

            let nonGameMarkers = [
                "politician", "singer", "musician", "rapper", "actor",
                "actress", "author", "novelist", "film", "movie",
                "television", "tv series", "album", "song ", "band",
                "rugby", "football", "basketball", "baseball player",
                "town", "village", "city in", "district", "commune",
                "species", "genus", "plant", "animal", "bird",
                "politician,", "writer", "poet",
                "政治家", "歌手", "俳優", "女優", "作家",
            ]
            for marker in nonGameMarkers where description.contains(marker) || descriptionRaw.contains(marker) {
                completion(false)
                return
            }

            let gamePhrases = [
                "video game", "is a game", "playstation", "ps1", "ps one",
                "for the playstation", "game developed", "game published",
                "platform game", "role-playing game", "action game",
            ]
            for phrase in gamePhrases where extract.contains(phrase) {
                completion(true)
                return
            }

            if Self.extractSuggestsVideoGame(extractRaw) {
                completion(true)
                return
            }

            completion(false)
        }
    }

    private static func descriptionSuggestsVideoGame(_ raw: String) -> Bool {
        let markers = ["ゲーム", "游戏", "電玩", "電子遊戲", "電子游戏", "비디오 게임", "jeu vidéo", "videogioco", "videospiel", "videjuego", "видеоигра", "видеоигра", "لعبة فيديو"]
        for m in markers where raw.contains(m) { return true }
        return false
    }

    private static func extractSuggestsVideoGame(_ raw: String) -> Bool {
        let markers = [
            "ゲーム", "テレビゲーム", "プレイステーション", "テレビゲーム機",
            "电子游戏", "电子游艺", "電子遊戲", "電視遊戲", "视频游戏",
            "비디오 게임", "비디오게임", "플레이스테이션",
            "jeu vidéo", "jeu video", "videogioco", "videospiel", "videojuego",
            "jogo eletrônico", "jogo eletronico", "computerspel", "відеогра", "видеоигра",
            "لعبة فيديو", "لعبة كمبيوتر", "वीडियो गेम",
        ]
        let e = raw.lowercased()
        for m in markers where raw.contains(m) { return true }
        if e.contains("playstation") || e.contains("ps1") { return true }
        return false
    }

    private func fetchSummaryJSON(title: String, completion: @escaping @Sendable ([String: Any]?) -> Void) {
        fetchSummaryJSON(title: title, languages: Self.wikipediaLanguageFallbackChain(), completion: completion)
    }

    private func fetchSummaryJSON(title: String, languages: [String], completion: @escaping @Sendable ([String: Any]?) -> Void) {
        guard let lang = languages.first else {
            completion(nil)
            return
        }
        let rest = Array(languages.dropFirst())
        guard let url = Self.wikipediaRESTSummaryURL(for: title, wikiLang: lang) else {
            fetchSummaryJSON(title: title, languages: rest, completion: completion)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Sakura/1.0 (https://github.com; PlayStation emulator)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                self?.fetchSummaryJSON(title: title, languages: rest, completion: completion)
                return
            }
            completion(json)
        }
        .resume()
    }

    /// Hits MediaWiki's `list=search` action and returns the top result's title.
    private func wikipediaSearch(query: String, completion: @escaping @Sendable (String?) -> Void) {
        wikipediaSearch(query: query, languages: Self.wikipediaLanguageFallbackChain(), completion: completion)
    }

    private func wikipediaSearch(query: String, languages: [String], completion: @escaping @Sendable (String?) -> Void) {
        guard let lang = languages.first else {
            completion(nil)
            return
        }
        let rest = Array(languages.dropFirst())
        guard var comps = URLComponents(string: "https://\(Self.wikipediaHost(forWikiLang: lang))/w/api.php") else {
            wikipediaSearch(query: query, languages: rest, completion: completion)
            return
        }
        comps.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "5"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else {
            wikipediaSearch(query: query, languages: rest, completion: completion)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Sakura/1.0 (https://github.com; PlayStation emulator)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let queryObj = json["query"] as? [String: Any],
                  let results = queryObj["search"] as? [[String: Any]],
                  !results.isEmpty
            else {
                self?.wikipediaSearch(query: query, languages: rest, completion: completion)
                return
            }
            let score: ([String: Any]) -> Int = { dict in
                let t = ((dict["title"] as? String) ?? "").lowercased()
                let s = ((dict["snippet"] as? String) ?? "").lowercased()
                let tRaw = (dict["title"] as? String) ?? ""
                let sRaw = (dict["snippet"] as? String) ?? ""
                var pts = 0
                if t.contains("playstation") { pts += 35 }
                if s.contains("playstation") { pts += 25 }
                if tRaw.contains("プレイステーション") { pts += 35 }
                if sRaw.contains("プレイステーション") { pts += 25 }
                if t.contains("ps1") || t.contains("ps one") { pts += 30 }
                if s.contains("ps1") || s.contains("ps one") { pts += 20 }
                if t.contains("video game") { pts += 15 }
                if s.contains("video game") { pts += 10 }
                if tRaw.contains("ゲーム") { pts += 12 }
                if sRaw.contains("ゲーム") { pts += 8 }
                if t.range(of: "\\b(199[4-9]|200[0-6])\\b", options: .regularExpression) != nil { pts += 30 }
                if s.range(of: "\\b(199[4-9]|200[0-6])\\b", options: .regularExpression) != nil { pts += 15 }
                if t.contains("(") { pts += 5 }
                return pts
            }
            let ranked = results.sorted { score($0) > score($1) }
            if let best = ranked.first, score(best) > 0 {
                completion(best["title"] as? String)
                return
            }
            completion(results.first?["title"] as? String)
        }
        .resume()
    }

    private func fetchWikipediaInfobox(
        title: String,
        sectionZeroOnly: Bool,
        completion: @escaping @Sendable (GameInfo?) -> Void
    ) {
        fetchWikipediaInfobox(title: title, sectionZeroOnly: sectionZeroOnly, languages: Self.wikipediaLanguageFallbackChain(), completion: completion)
    }

    private func fetchWikipediaInfobox(
        title: String,
        sectionZeroOnly: Bool,
        languages: [String],
        completion: @escaping @Sendable (GameInfo?) -> Void
    ) {
        guard let lang = languages.first else {
            completion(nil)
            return
        }
        let rest = Array(languages.dropFirst())
        guard var comps = URLComponents(string: "https://\(Self.wikipediaHost(forWikiLang: lang))/w/api.php") else {
            fetchWikipediaInfobox(title: title, sectionZeroOnly: sectionZeroOnly, languages: rest, completion: completion)
            return
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "action", value: "parse"),
            URLQueryItem(name: "page", value: title),
            URLQueryItem(name: "prop", value: "wikitext"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "redirects", value: "1"),
        ]
        if sectionZeroOnly {
            items.append(URLQueryItem(name: "section", value: "0"))
        }
        comps.queryItems = items
        guard let url = comps.url else {
            fetchWikipediaInfobox(title: title, sectionZeroOnly: sectionZeroOnly, languages: rest, completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Sakura/1.0 (https://github.com; PlayStation emulator)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parse = json["parse"] as? [String: Any],
                  let wikitext = (parse["wikitext"] as? [String: Any])?["*"] as? String
            else {
                self?.fetchWikipediaInfobox(title: title, sectionZeroOnly: sectionZeroOnly, languages: rest, completion: completion)
                return
            }

            let scoped = Self.isolateInfoboxBlock(wikitext) ?? wikitext

            var info = GameInfo.unknown
            if let release = Self.extractInfoboxField(scoped, keys: ["released", "release date", "release", "発売日", "リリース"]) {
                info.releaseDate = release
            }
            if let genre = Self.extractInfoboxField(scoped, keys: ["genre", "genres", "ジャンル", "タイプ", "类型", "類型"]) {
                info.genre = genre
            }
            if let dev = Self.extractInfoboxField(scoped, keys: ["developer", "developers", "開発元", "開発", "开发", "開發"]) {
                info.developer = dev
            }
            if let pub = Self.extractInfoboxField(scoped, keys: ["publisher", "publishers", "発売元", "发行", "發行"]) {
                info.publisher = pub
            }
            completion(info)
        }
        .resume()
    }

    private func writeInfo(_ info: GameInfo, forSerial serial: String) {
        let key = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let url = infoDiskURL(forCacheKey: key)
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: url)
    }

    // MARK: - User edits

    /// Fields the user can edit in-place from the library UI.
    enum EditableField: String {
        case title, releaseDate, genre, developer, publisher
    }

    /// Overwrite a single field in the persisted game info. Creates a record
    /// if none exists yet so edits made before a Wikipedia lookup still stick.
    func updateField(_ field: EditableField, to newValue: String, forSerial serial: String) {
        let key = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            var info = self.cachedInfo(forSerial: key) ?? GameInfo.unknown
            let value = trimmed.isEmpty ? "Unknown" : trimmed

            switch field {
            case .title:       info.title = trimmed     // title stays empty-allowed; display layer handles fallback
            case .releaseDate: info.releaseDate = value
            case .genre:       info.genre = value
            case .developer:   info.developer = value
            case .publisher:   info.publisher = value
            }
            self.writeInfo(info, forSerial: key)
        }
    }

    /// Strips demo/region annotations and trailing whitespace so "0 Story [Trial]"
    /// or "Resident Evil 4 (USA)" resolve to their main Wikipedia article.
    private static func normalizeTitleForLookup(_ title: String) -> String {
        var s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(
            pattern: "\\s*[\\[\\(][^\\]\\)]+[\\]\\)]\\s*$",
            options: []
        ) {
            while let match = regex.firstMatch(
                in: s, range: NSRange(s.startIndex..., in: s)
            ), let range = Range(match.range, in: s) {
                s.removeSubrange(range)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Infobox parsing helpers

    /// Returns the substring that starts at the first `{{Infobox …` and
    /// ends at its matching closing `}}`. Walks the wikitext character-by-
    /// character tracking brace depth, which correctly handles the nested
    /// templates that show up inside infoboxes (`{{vgrelease}}`,
    /// `{{plainlist}}`, etc.). Returns nil if there's no Infobox on the page.
    private static func isolateInfoboxBlock(_ wikitext: String) -> String? {
        let ns = wikitext as NSString
        guard let regex = try? NSRegularExpression(
            pattern: "\\{\\{\\s*Infobox\\b",
            options: [.caseInsensitive]
        ),
              let match = regex.firstMatch(
                in: wikitext,
                range: NSRange(location: 0, length: ns.length)
              )
        else { return nil }

        let start = match.range.location
        var depth = 0
        var i = start
        while i < ns.length - 1 {
            let pair = ns.substring(with: NSRange(location: i, length: 2))
            if pair == "{{" {
                depth += 1
                i += 2
            } else if pair == "}}" {
                depth -= 1
                i += 2
                if depth == 0 {
                    return ns.substring(with: NSRange(location: start, length: i - start))
                }
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func extractInfoboxField(_ wikitext: String, keys: [String]) -> String? {
        for key in keys {
            let pattern =
                "\\|\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*" +
                "((?:(?!\\n\\s*\\|)(?!\\n\\s*\\}\\})[\\s\\S])*)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(wikitext.startIndex..., in: wikitext)
            guard let m = regex.firstMatch(in: wikitext, range: range),
                  m.numberOfRanges >= 2,
                  let swiftRange = Range(m.range(at: 1), in: wikitext)
            else { continue }
            let raw = String(wikitext[swiftRange])
            let cleaned = cleanupWikitextValue(raw)
            if !cleaned.isEmpty, cleaned.lowercased() != "unknown" { return cleaned }
        }
        return nil
    }

    /// Strip MediaWiki markup: links, refs, templates, bold/italic, HTML tags.
    /// handles the common video-game infobox shapes: {{vgrelease}}, {{start
    /// date}}, plain wikilinks, and multi-value lists.
    private static func cleanupWikitextValue(_ raw: String) -> String {
        var s = raw

        // <ref…>…</ref>  /  <ref…/>
        if let regex = try? NSRegularExpression(pattern: "<ref[^>]*>[\\s\\S]*?</ref>", options: [.caseInsensitive]) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: "<ref[^>]*/>", options: [.caseInsensitive]) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }

        // {{start date|2004|11|9}} → 2004-11-09
        if let regex = try? NSRegularExpression(
            pattern: "\\{\\{\\s*(?:start\\s+date|end\\s+date)\\s*\\|\\s*(\\d{4})(?:\\s*\\|\\s*(\\d{1,2}))?(?:\\s*\\|\\s*(\\d{1,2}))?[^}]*\\}\\}",
            options: [.caseInsensitive]
        ) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let year = ns.substring(with: m.range(at: 1))
                let month = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
                let day = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
                var repl = year
                if !month.isEmpty {
                    repl += "-\(month.count == 1 ? "0" + month : month)"
                    if !day.isEmpty {
                        repl += "-\(day.count == 1 ? "0" + day : day)"
                    }
                }
                s = (s as NSString).replacingCharacters(in: m.range, with: repl)
            }
        }

        // {{vgrelease|NA|March 22, 2005|PAL|April 8, 2005}} → March 22, 2005 (NA), April 8, 2005 (PAL)
        if let regex = try? NSRegularExpression(
            pattern: "\\{\\{\\s*vgrelease(?:\\s+new)?\\s*\\|([^}]*)\\}\\}",
            options: [.caseInsensitive]
        ) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let inner = ns.substring(with: m.range(at: 1))
                let parts = inner
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                var pairs: [String] = []
                var i = 0
                while i + 1 < parts.count {
                    let region = parts[i]
                    let date = parts[i + 1]
                    if !region.isEmpty && !date.isEmpty {
                        pairs.append("\(date) (\(region))")
                    }
                    i += 2
                }
                s = (s as NSString).replacingCharacters(in: m.range, with: pairs.joined(separator: ", "))
            }
        }

        // {{nowrap|X}} / {{nobr|X}} / {{small|X}} / {{nbsp}} → just keep the argument.
        if let regex = try? NSRegularExpression(
            pattern: "\\{\\{\\s*(?:nowrap|nobr|small|smaller|big|nbsp|ubl|plainlist|flatlist|hlist|unbulleted list|ill|lang|transl)\\s*\\|?([^}]*)\\}\\}",
            options: [.caseInsensitive]
        ) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let inner = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
                // For list templates the args are pipe-separated — join with ", ".
                let joined = inner
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                s = (s as NSString).replacingCharacters(in: m.range, with: joined)
            }
        }

        // Drop any remaining templates wholesale — {{cvt|...}}, {{fact}}, etc.
        // Repeat to collapse nested patterns left behind by the above passes.
        if let regex = try? NSRegularExpression(pattern: "\\{\\{[^{}]*\\}\\}", options: []) {
            var previous = ""
            while previous != s {
                previous = s
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        }

        // [[Foo|Bar]] → Bar ; [[Baz]] → Baz
        if let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\]\\|]+)\\|([^\\]]+)\\]\\]", options: []) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$2")
        }
        if let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\]]+)\\]\\]", options: []) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        }

        // Bold/italic MediaWiki markup: '''bold''' / ''italic''.
        if let regex = try? NSRegularExpression(pattern: "'{5}([^']+)'{5}", options: []) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        }
        if let regex = try? NSRegularExpression(pattern: "'{3}([^']+)'{3}", options: []) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        }
        if let regex = try? NSRegularExpression(pattern: "'{2}([^']+)'{2}", options: []) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        }

        // <br> / <br/> → comma.
        if let regex = try? NSRegularExpression(pattern: "<br\\s*/?>", options: [.caseInsensitive]) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: ", ")
        }

        // Strip any other HTML tags.
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }

        // Collapse whitespace and trim.
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        s = s.replacingOccurrences(of: "\n", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Join multi-value fields with a comma if the wikitext used bullets.
        if s.contains("*") {
            let parts = s
                .split(whereSeparator: { $0 == "*" })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            s = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        // Drop trailing separators.
        while let last = s.last, last == "," || last == ";" || last == "/" || last == "|" {
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Collapse doubled separators like ", , " that templates can leave behind.
        while s.contains(", ,") { s = s.replacingOccurrences(of: ", ,", with: ",") }
        while s.contains(",,") { s = s.replacingOccurrences(of: ",,", with: ",") }

        return s
    }
}
