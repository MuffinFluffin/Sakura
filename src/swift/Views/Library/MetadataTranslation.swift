// SPDX-License-Identifier: GPL-3.0+
import CryptoKit
import Foundation
import SwiftUI

private enum MetadataTranslateCacheBox {
    nonisolated(unsafe) static let cache = NSCache<NSString, NSString>()
}

nonisolated enum MetadataWebTranslator {
    private static let failureSentinel = "__FAIL__"
    private static let myMemoryHost = URL(string: "https://api.mymemory.translated.net/get")!
    private static let maxQueryUTF8Bytes = 480

    private struct MemoryResponse: Decodable {
        struct DataBlock: Decodable {
            let translatedText: String
        }
        let responseData: DataBlock
        let quotaFinished: Bool?
    }

    static func langPairFragment(forDisplayLocale locale: Locale) -> String? {
        let lc = locale.language.languageCode?.identifier.lowercased() ?? ""
        guard lc != "en" else { return nil }
        let lid = normalizeLocaleID(locale.identifier)

        if lid.hasPrefix("zh-hans") || lid == "zh-cn" { return "zh-CN" }
        if lid.hasPrefix("zh-hant") || ["zh-tw", "zh-hk", "zh-mo"].contains(lid) { return "zh-TW" }
        if lid.hasPrefix("pt-br") || lid.hasPrefix("pt-pt") { return "pt" }
        if lid.hasPrefix("es-419") || lid.hasPrefix("es-mx") || lid.hasPrefix("es-ar")
            || lid.hasPrefix("es-co") || lid.hasPrefix("es-cl") {
            return "es"
        }

        switch lc {
        case "ja": return "ja"
        case "ko": return "ko"
        case "zh": return lid.contains("hant") || lid.hasSuffix("-tw") || lid.hasSuffix("-hk") || lid.hasSuffix("-mo")
            ? "zh-TW"
            : "zh-CN"
        case "es": return "es"
        case "fr": return "fr"
        case "de": return "de"
        case "pt": return "pt"
        case "it": return "it"
        case "ru": return "ru"
        case "nl": return "nl"
        case "pl": return "pl"
        case "tr": return "tr"
        case "vi": return "vi"
        case "id": return "id"
        case "th": return "th"
        case "sv": return "sv"
        case "da": return "da"
        case "fi": return "fi"
        case "nb", "nn", "no": return "nb"
        case "uk": return "uk"
        case "cs": return "cs"
        case "ro": return "ro"
        case "hu": return "hu"
        case "he": return "he"
        case "hi": return "hi"
        case "bn": return "bn"
        case "ar": return "ar"
        case "ms": return "ms"
        case "fil":
            return "tl"
        default:
            if (2 ... 3).contains(lc.count) { return lc }
            return nil
        }
    }

    static func translateAssumeEnglish(trimmed english: String, displayLocale locale: Locale) async -> String? {
        guard english.count <= 65536 else { return nil }
        guard let tgt = langPairFragment(forDisplayLocale: locale) else { return nil }
        let key = NSString(string: stableCacheKey(locale: locale, english: english))
        if Task.isCancelled { return nil }
        if let obj = MetadataTranslateCacheBox.cache.object(forKey: key) {
            let s = (obj as NSString) as String
            if s == failureSentinel { return nil }
            return s
        }

        func storeFailure() {
            MetadataTranslateCacheBox.cache.setObject(failureSentinel as NSString, forKey: key)
        }

        if english.utf8.count <= maxQueryUTF8Bytes {
            guard let piece = await fetchMyMemory(segment: english, targetTag: tgt) else {
                storeFailure()
                return nil
            }
            MetadataTranslateCacheBox.cache.setObject(piece as NSString, forKey: key)
            return piece
        }
        let parts = utf8Chunks(english)
        var out: [String] = []
        out.reserveCapacity(parts.count)
        for p in parts {
            if Task.isCancelled {
                storeFailure()
                return nil
            }
            guard let translated = await fetchMyMemory(segment: p, targetTag: tgt) else {
                storeFailure()
                return nil
            }
            out.append(translated)
            try? await Task.sleep(nanoseconds: 85_000_000)
        }
        let merged = out.joined()
        MetadataTranslateCacheBox.cache.setObject(merged as NSString, forKey: key)
        return merged
    }

    private static func stableCacheKey(locale: Locale, english: String) -> String {
        let localeTag = normalizeLocaleID(locale.identifier)
        let digest = SHA256.hash(data: Data(english.utf8))
        let stamp = digest.prefix(10).reduce(into: "") { $0.append(String(format: "%02x", $1)) }
        return localeTag + "|" + stamp
    }

    private static func normalizeLocaleID(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func utf8Chunks(_ full: String) -> [String] {
        let utf8Array = Array(full.utf8)
        if utf8Array.count <= maxQueryUTF8Bytes { return [full] }
        var chunks: [String] = []
        var i = 0
        while i < utf8Array.count {
            var end = min(i + maxQueryUTF8Bytes, utf8Array.count)
            if end < utf8Array.count {
                while end > i + 8, (utf8Array[end - 1] & 0xC0) == 0x80 {
                    end -= 1
                }
                if end == i {
                    end = min(i + maxQueryUTF8Bytes, utf8Array.count)
                }
            }
            let sliceBytes = utf8Array[i ..< end]
            guard let decoded = String(bytes: sliceBytes, encoding: .utf8) else {
                break
            }
            chunks.append(decoded)
            i = end
        }
        return chunks.isEmpty ? [full] : chunks
    }

    private static func fetchMyMemory(segment: String, targetTag: String) async -> String? {
        let pair = "en|" + targetTag.lowercased()
        var comps = URLComponents(url: myMemoryHost, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: segment),
            URLQueryItem(name: "langpair", value: pair),
            URLQueryItem(name: "mt", value: "1"),
        ]
        guard let url = comps.url else { return nil }

        func oneShot() async -> String? {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 22)
            req.setValue("Sakura/1.0 (metadata blurbs)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if Task.isCancelled { return nil }
                guard let http = response as? HTTPURLResponse else { return nil }
                guard (200 ... 299).contains(http.statusCode) else { return nil }
                let decoded = try JSONDecoder().decode(MemoryResponse.self, from: data)
                if decoded.quotaFinished == true { return nil }
                let trimmedAnswer = decoded.responseData.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedAnswer.isEmpty else { return nil }
                return trimmedAnswer
            } catch {
                return nil
            }
        }

        guard let first = await oneShot() else {
            try? await Task.sleep(nanoseconds: 180_000_000)
            return await oneShot()
        }
        return first
    }
}

struct RunningGameSnapshot: Sendable {
    let isoFileName: String
    let displayTitle: String
    let summary: String
    let releaseDate: String
    let genre: String
    let developer: String
    let publisher: String
    let sizeBytes: UInt64

    static func current() -> RunningGameSnapshot? {
        guard let path = SakuraBridge.currentISOPath(), !path.isEmpty else { return nil }

        let isoFileName = (path as NSString).lastPathComponent
        let serial = SakuraBridge.isoSerial(forPath: path)
        let metadataKey: String
        if let serial, !serial.isEmpty {
            metadataKey = serial
        } else {
            let safe = isoFileName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? isoFileName
            metadataKey = "file-\(safe)"
        }

        let fm = FileManager.default
        let cached = GameMetadataService.shared.cachedInfo(forSerial: metadataKey)

        let baseName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let diskTitle = SakuraBridge.isoTitle(forPath: path)

        let displayTitle: String
        if let t = cached?.title, !t.isEmpty {
            displayTitle = t
        } else if let dt = diskTitle, !dt.isEmpty {
            displayTitle = dt
        } else {
            displayTitle = baseName
        }

        let summary = cached?.summary ?? ""
        let releaseDate = cached?.releaseDate ?? "Unknown"
        let genre = cached?.genre ?? "Unknown"
        let developer = cached?.developer ?? "Unknown"
        let publisher = cached?.publisher ?? "Unknown"
        let sizeBytes = ((try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0

        return RunningGameSnapshot(
            isoFileName: isoFileName,
            displayTitle: displayTitle,
            summary: summary,
            releaseDate: releaseDate,
            genre: genre,
            developer: developer,
            publisher: publisher,
            sizeBytes: sizeBytes
        )
    }
}

private struct WebTranslatedMetadataParagraph: View {
    let trimmed: String
    var font: Font = .subheadline
    var lineLimit: Int? = nil
    var minimumScale: CGFloat = 1.0
    var reservesSpace: Bool = false
    var truncationMode: Text.TruncationMode = .tail

    @State private var overlay: String?

    var body: some View {
        let shown = overlay ?? trimmed
        Group {
            if let lineLimit {
                Text(shown)
                    .font(font)
                    .lineLimit(lineLimit, reservesSpace: reservesSpace)
                    .truncationMode(truncationMode)
                    .minimumScaleFactor(minimumScale)
            } else {
                Text(shown)
                    .font(font)
                    .truncationMode(truncationMode)
                    .minimumScaleFactor(minimumScale)
            }
        }
        .task(id: TranslatedGameMetadataLine.metadataTranslateTaskToken(trimmed: trimmed)) {
            overlay = nil
            guard TranslatedGameMetadataLine.shouldFetchOnlineTranslation(trimmed: trimmed) else { return }
            let loc = SakuraL10n.effectiveFormatLocale()
            guard MetadataWebTranslator.langPairFragment(forDisplayLocale: loc) != nil else { return }
            guard let translated = await MetadataWebTranslator.translateAssumeEnglish(
                trimmed: trimmed,
                displayLocale: loc
            ) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                overlay = translated
            }
        }
    }
}

struct TranslatedGameMetadataLine: View {
    let englishRaw: String
    var font: Font = .subheadline
    var lineLimit: Int? = nil
    var minimumScale: CGFloat = 1.0
    var reservesSpace: Bool = false
    var truncationMode: Text.TruncationMode = .tail

    private var trimmed: String {
        englishRaw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func metadataTranslateTaskToken(trimmed taskText: String) -> String {
        SakuraL10n.effectiveFormatLocale().identifier.replacingOccurrences(of: "_", with: "-") + "|"
            + "\(taskText.utf8.count)|"
            + String(taskText.prefix(9216))
    }

    var body: some View {
        if trimmed.isEmpty {
            plainText(" ")
        } else if trimmed.caseInsensitiveCompare("unknown") == .orderedSame {
            plainText(SakuraL10n.tr("metadata.unknown"))
        } else if Self.shouldFetchOnlineTranslation(trimmed: trimmed) {
            WebTranslatedMetadataParagraph(
                trimmed: trimmed,
                font: font,
                lineLimit: lineLimit,
                minimumScale: minimumScale,
                reservesSpace: reservesSpace,
                truncationMode: truncationMode
            )
        } else {
            plainText(trimmed)
        }
    }

    fileprivate static func shouldFetchOnlineTranslation(trimmed t: String) -> Bool {
        guard !t.isEmpty else { return false }
        let loc = SakuraL10n.effectiveFormatLocale()
        guard let lc = loc.language.languageCode?.identifier.lowercased(), lc != "en" else { return false }
        return !sakuraAppearsTranslatedForTarget(trimmed: t, targetLanguageCode: lc)
            && sakuraMetadataWebTranslatorHasRoute(forDisplayLocale: loc)
    }

    private static func sakuraMetadataWebTranslatorHasRoute(forDisplayLocale locale: Locale) -> Bool {
        MetadataWebTranslator.langPairFragment(forDisplayLocale: locale) != nil
    }

    private static func sakuraAppearsTranslatedForTarget(trimmed t: String, targetLanguageCode lc: String) -> Bool {
        if lc == "ja" {
            return t.unicodeScalars.lazy.filter {
                switch $0.value {
                case 0x3040 ... 0x309F, 0x30A0 ... 0x30FF:
                    true
                default:
                    false
                }
            }.prefix(64).count >= 8
        }
        if lc.hasPrefix("zh") || lc == "yue" {
            return t.unicodeScalars.lazy.filter { (0x4E00 ... 0x9FFF).contains($0.value) }.prefix(112).count >= 18
        }
        if lc == "ko" {
            return t.unicodeScalars.lazy.filter { (0xAC00 ... 0xD7AF).contains($0.value) }.prefix(72).count >= 8
        }
        if lc.hasPrefix("ar") {
            let range: ClosedRange<UInt32> = 0x0600 ... 0x06FF
            return t.unicodeScalars.lazy.filter { range.contains(UInt32($0.value)) }.prefix(96).count >= 22
        }
        return false
    }

    @ViewBuilder
    private func plainText(_ s: String) -> some View {
        Group {
            if let lineLimit {
                Text(s)
                    .font(font)
                    .lineLimit(lineLimit, reservesSpace: reservesSpace)
                    .truncationMode(truncationMode)
                    .minimumScaleFactor(minimumScale)
            } else {
                Text(s)
                    .font(font)
                    .truncationMode(truncationMode)
                    .minimumScaleFactor(minimumScale)
            }
        }
    }
}
