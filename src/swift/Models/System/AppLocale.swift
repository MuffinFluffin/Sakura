// SPDX-License-Identifier: GPL-3.0+

import Foundation

enum AppLocale {
    static let appStorageKey = "sakura.app.localeOverride"

    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let options: [Option] = [
        Option(id: "", label: "System default"),
        Option(id: "en", label: "English"),
        Option(id: "ja", label: "日本語"),
        Option(id: "es", label: "Español"),
        Option(id: "es-419", label: "Español (Latinoamérica)"),
        Option(id: "fr", label: "Français"),
        Option(id: "de", label: "Deutsch"),
        Option(id: "pt-BR", label: "Português (Brasil)"),
        Option(id: "pt-PT", label: "Português (Portugal)"),
        Option(id: "ko", label: "한국어"),
        Option(id: "zh-Hans", label: "简体中文"),
        Option(id: "zh-Hant", label: "繁體中文"),
        Option(id: "it", label: "Italiano"),
        Option(id: "ru", label: "Русский"),
        Option(id: "nl", label: "Nederlands"),
        Option(id: "pl", label: "Polski"),
        Option(id: "sv", label: "Svenska"),
        Option(id: "nb", label: "Norsk (bokmål)"),
        Option(id: "da", label: "Dansk"),
        Option(id: "fi", label: "Suomi"),
        Option(id: "uk", label: "Українська"),
        Option(id: "ro", label: "Română"),
        Option(id: "cs", label: "Čeština"),
        Option(id: "hu", label: "Magyar"),
        Option(id: "tr", label: "Türkçe"),
        Option(id: "vi", label: "Tiếng Việt"),
        Option(id: "id", label: "Bahasa Indonesia"),
        Option(id: "ms", label: "Bahasa Melayu"),
        Option(id: "fil", label: "Filipino"),
        Option(id: "th", label: "ไทย"),
        Option(id: "ar", label: "العربية"),
        Option(id: "he", label: "עברית"),
        Option(id: "hi", label: "हिन्दी"),
        Option(id: "bn", label: "বাংলা"),
    ]

    static func resolvedLocale(rawOverride: String) -> Locale {
        if rawOverride.isEmpty { return Locale.autoupdatingCurrent }
        return Locale(identifier: rawOverride)
    }

    static func localizedLanguageLabel(for option: Option, overrideRaw: String) -> String {
        if option.id.isEmpty { return SakuraL10n.tr("locale.system") }
        let trimmed = overrideRaw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let presenter = trimmed.isEmpty ? Locale.autoupdatingCurrent : Locale(identifier: trimmed)
        let name = presenter.localizedString(forIdentifier: option.id)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return option.label
    }

    private static func normalizeLangTag(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func seedLocaleFromSystemWhenUnsetAndOnboardingIncomplete(onboardingCompleted: Bool) {
        guard !onboardingCompleted else { return }
        let raw = UserDefaults.standard.string(forKey: appStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard raw.isEmpty else { return }
        guard let id = preferredBundledLocaleId() else { return }
        UserDefaults.standard.set(id, forKey: appStorageKey)
    }

    private static func preferredBundledLocaleId() -> String? {
        let bundled = Set(options.map(\.id).filter { !$0.isEmpty })
        var candidates: [String] = []
        var seen = Set<String>()
        func push(_ s: String) {
            let t = normalizeLangTag(s)
            guard !t.isEmpty else { return }
            if seen.insert(t).inserted { candidates.append(t) }
        }

        for pref in Locale.preferredLanguages.prefix(10) {
            push(pref)
            let loc = Locale(identifier: normalizeLangTag(pref))
            if let lc = loc.language.languageCode?.identifier { push(lc) }
            if let lc = loc.language.languageCode?.identifier,
               let sc = loc.language.script?.identifier,
               !sc.isEmpty {
                push("\(lc)-\(sc)")
            }
        }

        for cand in candidates {
            if bundled.contains(cand) { return cand }
        }

        for cand in candidates {
            let lower = cand.lowercased()
            if lower.hasPrefix("zh-hans") || lower == "zh-cn" {
                if bundled.contains("zh-Hans") { return "zh-Hans" }
            }
            if lower.hasPrefix("zh-hant") || ["zh-tw", "zh-hk", "zh-mo"].contains(lower) {
                if bundled.contains("zh-Hant") { return "zh-Hant" }
            }
            if lower.hasPrefix("es-419")
                || lower.hasPrefix("es-mx") || lower.hasPrefix("es-ar")
                || lower.hasPrefix("es-co") || lower.hasPrefix("es-cl") {
                if bundled.contains("es-419") { return "es-419" }
            }
            if lower.hasPrefix("es") {
                if bundled.contains("es") { return "es" }
            }
            if lower.hasPrefix("pt-br") {
                if bundled.contains("pt-BR") { return "pt-BR" }
            }
            if lower.hasPrefix("pt-pt") {
                if bundled.contains("pt-PT") { return "pt-PT" }
            }
            if lower.hasPrefix("pt") {
                if bundled.contains("pt-BR") { return "pt-BR" }
            }
            if lower.hasPrefix("no") || lower.hasPrefix("nb") {
                if bundled.contains("nb") { return "nb" }
            }
            if lower.hasPrefix("fil") || lower.hasPrefix("tl") {
                if bundled.contains("fil") { return "fil" }
            }
            if lower == "bn" || lower.hasPrefix("bn-") {
                if bundled.contains("bn") { return "bn" }
            }
        }

        return nil
    }
}

enum SakuraL10n {
    private static let sync = NSLock()
    nonisolated(unsafe) private static var bundles: [String: [String: String]] = [:]
    nonisolated(unsafe) private static var didScan = false

    static func loadIfNeeded(bundle: Bundle = .main) {
        sync.lock(); defer { sync.unlock() }
        scanUnlocked(bundle: bundle)
    }

    static func tr(_ key: String) -> String {
        sync.lock(); defer { sync.unlock() }
        scanUnlocked(bundle: .main)
        let chain = localeLookupOrderUnlocked()
        for id in chain {
            if let t = bundles[id]?[key], !t.isEmpty { return t }
        }
        if let t = bundles["en"]?[key], !t.isEmpty { return t }
        return key
    }

    static func trf(_ key: String, _ arguments: CVarArg...) -> String {
        let format = tr(key)
        return String(format: format, locale: effectiveFormatLocale(), arguments: arguments)
    }

    static func effectiveFormatLocale() -> Locale {
        let raw = UserDefaults.standard.string(forKey: AppLocale.appStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty { return Locale(identifier: raw) }
        return Locale.current
    }

    private static func scanUnlocked(bundle: Bundle) {
        guard !didScan else { return }
        guard let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "SakuraL10n"), !urls.isEmpty else {
            return
        }
        didScan = true
        var base: [String: URL] = [:]
        var overlay: [String: [URL]] = [:]

        for u in urls {
            let stem = u.deletingPathExtension().lastPathComponent
            let parts = stem.components(separatedBy: "__")
            if parts.count == 2, parts[1] == "more" {
                overlay[parts[0], default: []].append(u)
            } else if !stem.contains("__") {
                base[stem] = u
            }
        }

        let locales = Set(base.keys).union(overlay.keys)
        for loc in locales {
            var dict = readTable(base[loc]) ?? [:]
            for o in overlay[loc] ?? [] {
                dict.merge(readTable(o) ?? [:]) { _, n in n }
            }
            if !dict.isEmpty {
                bundles[loc] = dict
            }
        }
    }

    private static func readTable(_ url: URL?) -> [String: String]? {
        guard let url else { return nil }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        out.reserveCapacity(obj.count)
        for (k, v) in obj {
            guard let s = v as? String else { continue }
            out[k] = s
        }
        return out
    }

    private static func localeLookupOrderUnlocked() -> [String] {
        var order: [String] = []
        func push(_ s: String) {
            let t = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if !order.contains(t) { order.append(t) }
        }

        let raw = UserDefaults.standard.string(forKey: AppLocale.appStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty {
            push(normalizeLangTag(raw))
            let loc = Locale(identifier: normalizeLangTag(raw))
            if let lc = loc.language.languageCode?.identifier { push(lc) }
            if let lc = loc.language.languageCode?.identifier,
               let sc = loc.language.script?.identifier,
               !lc.isEmpty, !sc.isEmpty {
                push("\(lc)-\(sc)")
            }
        } else {
            for pref in Locale.preferredLanguages.prefix(5) {
                let tag = pref.replacingOccurrences(of: "_", with: "-")
                push(tag)
                if let lc = Locale(identifier: tag).language.languageCode?.identifier { push(lc) }
            }
        }
        push("en")
        return order
    }

    private static func normalizeLangTag(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}
