// SPDX-License-Identifier: GPL-3.0+

import Foundation
import SwiftUI
import Observation

struct AnnouncementPollConfig: Codable, Equatable {
    let maxSuccessfulFetchesPerRollingMinute: Int?
    let maxSuccessfulFetchesPerRollingHour: Int?
    let maxSuccessfulFetchesPerRollingDay: Int?
    let minSpacingSecondsBetweenAttempts: Double?
    let emergencyRelaxedUntilUTC: String?
}

struct AnnouncementLink: Equatable, Decodable {
    let label: String
    let url: String
    let icon: String?
    let tintKey: String?

    var parsedURL: URL? { URL(string: url) }
}

struct Announcement: Identifiable, Equatable {
    let id: String
    let type: AnnouncementType
    let title: String
    let body: String?
    let icon: String?
    let tintKey: String?
    let url: String?
    let links: [AnnouncementLink]?
    let minVersion: String?
    let maxVersion: String?
    let minBuild: Int?
    let maxBuild: Int?
    let expiresAt: String?
    let introSeconds: Int?
    let persistenceSeconds: Double?
    let recurrenceTotalShows: Int?
    let recurrenceIntervalSeconds: Double?
    let showAgainEveryColdLaunch: Bool?
    let maxColdLaunchDisplays: Int?

    enum AnnouncementType: String, Codable {
        case card
        case fullscreen
    }

    var parsedExpiry: Date? {
        guard let expiresAt else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: expiresAt) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: expiresAt)
    }

    var isExpired: Bool {
        guard let expiry = parsedExpiry else { return false }
        return Date() > expiry
    }

    var linkURL: URL? {
        guard let url else { return nil }
        return URL(string: url)
    }

    /// Action buttons shown under the body. Combines the legacy `url`
    /// with the new `links` array. legacy url is appended last when
    /// it is not already represented in `links`.
    var actionLinks: [AnnouncementLink] {
        var out = links ?? []
        if let legacy = url, !legacy.isEmpty,
           !out.contains(where: { $0.url == legacy }) {
            out.append(AnnouncementLink(
                label: SakuraL10n.tr("common.learnMore"),
                url: legacy,
                icon: "arrow.up.right.square",
                tintKey: nil
            ))
        }
        return out
    }
}

extension Announcement: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case body
        case icon
        case tintKey
        case url
        case links
        case minVersion
        case maxVersion
        case minBuild
        case maxBuild
        case expiresAt
        case introSeconds
        case persistenceSeconds
        case recurrenceTotalShows
        case recurrenceIntervalSeconds
        case showAgainEveryColdLaunch
        case maxColdLaunchDisplays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(Announcement.AnnouncementType.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        tintKey = try c.decodeIfPresent(String.self, forKey: .tintKey)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        links = try c.decodeIfPresent([AnnouncementLink].self, forKey: .links)
        minVersion = try c.decodeIfPresent(String.self, forKey: .minVersion)
        maxVersion = try c.decodeIfPresent(String.self, forKey: .maxVersion)
        minBuild = Announcement.decodeFlexibleOptionalInt(container: c, key: .minBuild)
        maxBuild = Announcement.decodeFlexibleOptionalInt(container: c, key: .maxBuild)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
        introSeconds = try c.decodeIfPresent(Int.self, forKey: .introSeconds)
        persistenceSeconds = try c.decodeIfPresent(Double.self, forKey: .persistenceSeconds)
        recurrenceTotalShows = Announcement.decodeFlexibleOptionalInt(container: c, key: .recurrenceTotalShows)
        recurrenceIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .recurrenceIntervalSeconds)
        showAgainEveryColdLaunch = try c.decodeIfPresent(Bool.self, forKey: .showAgainEveryColdLaunch)
        maxColdLaunchDisplays = Announcement.decodeFlexibleOptionalInt(container: c, key: .maxColdLaunchDisplays)
    }

    private static func decodeFlexibleOptionalInt(container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let x = try? container.decodeIfPresent(Int.self, forKey: key) {
            return x
        }
        if let d = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(d.rounded(.towardZero))
        }
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstDigit = stripped.firstIndex(where: { $0.isNumber }) else { return nil }
        var digits = ""
        for ch in stripped[firstDigit...] {
            if ch.isWholeNumber {
                digits.append(ch)
                if digits.count > 12 { break }
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }
}

private enum AppInstallFingerprint {
    private static func marketingVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
    }

    static func normalizedNumericBuildNumber() -> Int {
        guard let raw = Bundle.main.infoDictionary?["CFBundleVersion"] else { return 0 }
        let s = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return leadingIntegerDigits(from: s) ?? 0
    }

    private static func leadingIntegerDigits(from s: String) -> Int? {
        guard let firstDigit = s.firstIndex(where: { $0.isNumber }) else { return nil }
        var digits = ""
        for ch in s[firstDigit...] {
            if ch.isWholeNumber {
                digits.append(ch)
                if digits.count > 14 { break }
            } else if !digits.isEmpty {
                break
            }
        }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    static func passesVersionAndBuildGate(for a: Announcement) -> Bool {
        let mv = marketingVersion()
        let buildNum = normalizedNumericBuildNumber()
        if let minV = a.minVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !minV.isEmpty,
           mv.compare(minV, options: .numeric) == .orderedAscending {
            return false
        }
        if let maxV = a.maxVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !maxV.isEmpty,
           mv.compare(maxV, options: .numeric) != .orderedAscending {
            return false
        }
        if let mb = a.minBuild {
            if buildNum < mb { return false }
        }
        if let xb = a.maxBuild {
            if buildNum > xb { return false }
        }
        return true
    }
}

struct AnnouncementManifest: Decodable {
    let announcements: [Announcement]
    let poll: AnnouncementPollConfig?
}

private enum AnnouncementFetchKeys {
    static let successTimestamps = "sakura.announcements.fetchSuccessUnixTimes"
    static let lastAttemptUnix = "sakura.announcements.fetchLastAttemptUnix"
    static let persistedPollHints = "sakura.announcements.persistedPollHintsJSON"
    static let coldLaunchImpressionsJSON = "sakura.announcements.coldLaunchImpressionsJSON"
}

@Observable
@MainActor
final class AnnouncementManager {
    static let shared = AnnouncementManager()

    private static let manifestURL = URL(string: "https://raw.githubusercontent.com/MuffinFluffin/Sakura-Announcements/main/announcements.json")!

    private static let builtinCaps = BuiltinFetchCaps()

    private struct BuiltinFetchCaps {
        let rollingMinuteWindow: TimeInterval = 60
        let rollingHourWindow: TimeInterval = 3600
        let rollingDayWindow: TimeInterval = 86_400
        let defaultMaxSuccessPerMinute = 2
        let defaultMaxSuccessPerHour = 12
        let defaultMaxSuccessPerDay = 48
        let defaultMinSpacingBetweenAttempts: TimeInterval = 90
        let emergencySuccessCapMultiplier: Double = 2
    }

    private(set) var pendingFullscreen: [Announcement] = []

    var activeFullscreen: Announcement? = nil

    private let dismissedKey = "sakura.announcements.dismissed"
    private var recurringCampaignIdsInFlight = Set<String>()

    private var dismissedIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: dismissedKey)
        }
    }

    private init() {}

    func userDismissedManifestAnnouncement(id: String) {
        recurringCampaignIdsInFlight.remove(id)
        markDismissed(id)
    }

    func timedDismissFinishedForManifestAnnouncement(id: String, shouldEraseDismissedManifestEntry: Bool) {
        recurringCampaignIdsInFlight.remove(id)
        if shouldEraseDismissedManifestEntry {
            markDismissed(id)
        }
    }

    // MARK: - Fetch & Process

    func fetchAndProcess() {
        let now = Date()
        guard canStartFetchAttempt(now: now) else { return }
        markAttempt(now: now)
        Task {
            await performManifestFetch()
        }
    }

    private func canStartFetchAttempt(now: Date) -> Bool {
        let caps = mergedFetchCaps(reference: now)
        let d = UserDefaults.standard

        let lastTU = d.double(forKey: AnnouncementFetchKeys.lastAttemptUnix)
        if lastTU > 0 {
            let elapsed = now.timeIntervalSince1970 - lastTU
            if elapsed < caps.minSpacingAttempts {
                return false
            }
        }

        let successes = loadedSuccessUnixTimes(reference: now)
        if rollingCount(successes: successes, within: Self.builtinCaps.rollingMinuteWindow, now: now) >= caps.successPerRollingMinute {
            return false
        }
        if rollingCount(successes: successes, within: Self.builtinCaps.rollingHourWindow, now: now) >= caps.successPerRollingHour {
            return false
        }
        if rollingCount(successes: successes, within: Self.builtinCaps.rollingDayWindow, now: now) >= caps.successPerRollingDay {
            return false
        }
        return true
    }

    private func markAttempt(now: Date) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: AnnouncementFetchKeys.lastAttemptUnix)
    }

    private func mergedFetchCaps(reference now: Date) -> (
        successPerRollingMinute: Int,
        successPerRollingHour: Int,
        successPerRollingDay: Int,
        minSpacingAttempts: TimeInterval
    ) {
        let saved = persistedPollHints()
        var perMin = clampNonNegative(saved?.maxSuccessfulFetchesPerRollingMinute) ?? Self.builtinCaps.defaultMaxSuccessPerMinute
        var perHr = clampNonNegative(saved?.maxSuccessfulFetchesPerRollingHour) ?? Self.builtinCaps.defaultMaxSuccessPerHour
        var perDay = clampNonNegative(saved?.maxSuccessfulFetchesPerRollingDay) ?? Self.builtinCaps.defaultMaxSuccessPerDay
        let spacing: Double = {
            if let s = saved?.minSpacingSecondsBetweenAttempts, s > 0 { return s }
            return Self.builtinCaps.defaultMinSpacingBetweenAttempts
        }()

        if relaxingFetchCaps(reference: now, persisted: saved) {
            let m = Self.builtinCaps.emergencySuccessCapMultiplier
            perMin = Int(ceil(Double(perMin) * m))
            perHr = Int(ceil(Double(perHr) * m))
            perDay = Int(ceil(Double(perDay) * m))
        }

        let spacingBounded = max(15, spacing)
        perMin = max(1, perMin)
        perHr = max(perMin, perHr)
        perDay = max(perHr, perDay)
        return (perMin, perHr, perDay, spacingBounded)
    }

    private func relaxingFetchCaps(reference now: Date, persisted: AnnouncementPollConfig?) -> Bool {
        guard let iso = persisted?.emergencyRelaxedUntilUTC else { return false }
        guard let until = ISO8601DateFormatter().date(from: iso) else { return false }
        return now < until
    }

    private func clampNonNegative(_ v: Int?) -> Int? {
        guard let v else { return nil }
        return max(0, v)
    }

    private func persistedPollHints() -> AnnouncementPollConfig? {
        guard let data = UserDefaults.standard.data(forKey: AnnouncementFetchKeys.persistedPollHints),
              let h = try? JSONDecoder().decode(AnnouncementPollConfig.self, from: data) else {
            return nil
        }
        return h
    }

    private func persistPollHints(_ poll: AnnouncementPollConfig?) {
        guard let poll else {
            UserDefaults.standard.removeObject(forKey: AnnouncementFetchKeys.persistedPollHints)
            return
        }
        if let data = try? JSONEncoder().encode(poll) {
            UserDefaults.standard.set(data, forKey: AnnouncementFetchKeys.persistedPollHints)
        }
    }

    private func loadedSuccessUnixTimes(reference now: Date) -> [TimeInterval] {
        let raw = (UserDefaults.standard.array(forKey: AnnouncementFetchKeys.successTimestamps) as? [Double])?.map { TimeInterval($0) } ?? []
        let pruneBefore = now.timeIntervalSince1970 - Self.builtinCaps.rollingDayWindow * 2
        let pruned = raw.filter { $0 >= pruneBefore }
        if pruned.count != raw.count {
            UserDefaults.standard.set(pruned, forKey: AnnouncementFetchKeys.successTimestamps)
        }
        return pruned
    }

    private func rollingCount(successes: [TimeInterval], within window: TimeInterval, now: Date) -> Int {
        let threshold = now.timeIntervalSince1970 - window
        return successes.reduce(0) { partial, unix in partial + ((unix >= threshold) ? 1 : 0) }
    }

    private func appendSuccessfulFetch(at date: Date) {
        let u = date.timeIntervalSince1970
        var s = loadedSuccessUnixTimes(reference: date)
        s.append(u)
        UserDefaults.standard.set(s, forKey: AnnouncementFetchKeys.successTimestamps)
    }

    private func performManifestFetch() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.manifestURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let manifest = try JSONDecoder().decode(AnnouncementManifest.self, from: data)
            if let hints = manifest.poll {
                persistPollHints(hints)
            }
            await MainActor.run {
                self.appendSuccessfulFetch(at: Date())
                let valid = manifest.announcements.filter { shouldShow($0) }
                self.processAnnouncements(valid)
            }
        } catch {}
    }

    private func coldLaunchCounts() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: AnnouncementFetchKeys.coldLaunchImpressionsJSON),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func setColdLaunchCount(_ count: Int, for id: String) {
        var d = coldLaunchCounts()
        d[id] = count
        if let data = try? JSONEncoder().encode(d) {
            UserDefaults.standard.set(data, forKey: AnnouncementFetchKeys.coldLaunchImpressionsJSON)
        }
    }

    private func shouldShow(_ a: Announcement) -> Bool {
        if dismissedIDs.contains(a.id) { return false }
        if recurringCampaignIdsInFlight.contains(a.id) { return false }
        if a.isExpired { return false }
        if !AppInstallFingerprint.passesVersionAndBuildGate(for: a) { return false }

        let coldRepeat = a.showAgainEveryColdLaunch ?? false
        if coldRepeat {
            let cap = a.maxColdLaunchDisplays ?? Int.max
            if cap != Int.max, coldLaunchCounts()[a.id, default: 0] >= cap {
                if !dismissedIDs.contains(a.id) {
                    markDismissed(a.id)
                }
                return false
            }
        }
        return true
    }

    private func processAnnouncements(_ announcements: [Announcement]) {
        for a in announcements {
            switch a.type {
            case .card:
                guard SakuraNotificationCenter.shared.enabled else { continue }
                let coldRepeat = a.showAgainEveryColdLaunch ?? false
                let totalShows = max(1, a.recurrenceTotalShows ?? 1)
                let gap = max(0, a.recurrenceIntervalSeconds ?? 0)
                var intro = a.introSeconds ?? 3
                var persist = a.persistenceSeconds ?? 8
                intro = max(0, intro)
                if coldRepeat || totalShows > 1 {
                    persist = persist > 0 ? persist : 8
                }
                let repeatRem = totalShows > 1 ? UInt(totalShows - 1) : UInt(0)
                let recurrenceGap = totalShows > 1 ? gap : 0

                let timedDismissEraseDismissedManifest = !coldRepeat

                let markImmediatelyDismissedLegacy =
                    !coldRepeat && totalShows <= 1

                if coldRepeat {
                    let cap = a.maxColdLaunchDisplays ?? Int.max
                    if cap != Int.max, coldLaunchCounts()[a.id, default: 0] >= cap {
                        continue
                    }
                    setColdLaunchCount(coldLaunchCounts()[a.id, default: 0] + 1, for: a.id)
                }

                let card = SakuraNotificationCenter.Card(
                    kind: .info,
                    title: a.title,
                    subtitle: a.body,
                    icon: a.icon ?? "megaphone.fill",
                    tintKey: a.tintKey,
                    introSeconds: intro,
                    persistence: persist,
                    recurrence: recurrenceGap,
                    repeatRemaining: repeatRem,
                    manifestAnnouncementId: a.id,
                    timedDismissEraseManifestDismissedState: timedDismissEraseDismissedManifest
                )
                SakuraNotificationCenter.shared.pushRaw(card)
                if markImmediatelyDismissedLegacy {
                    markDismissed(a.id)
                } else {
                    recurringCampaignIdsInFlight.insert(a.id)
                }

            case .fullscreen:
                let coldRepeat = a.showAgainEveryColdLaunch ?? false
                if coldRepeat {
                    let cap = a.maxColdLaunchDisplays ?? Int.max
                    if cap != Int.max, coldLaunchCounts()[a.id, default: 0] >= cap {
                        if !dismissedIDs.contains(a.id) {
                            markDismissed(a.id)
                        }
                        continue
                    }
                    setColdLaunchCount(coldLaunchCounts()[a.id, default: 0] + 1, for: a.id)
                }
                pendingFullscreen.append(a)
            }
        }
        showNextFullscreen()
    }

    func showNextFullscreen() {
        guard activeFullscreen == nil, !pendingFullscreen.isEmpty else { return }
        activeFullscreen = pendingFullscreen.removeFirst()
    }

    func dismissFullscreen() {
        if let current = activeFullscreen {
            userDismissedManifestAnnouncement(id: current.id)
        }
        activeFullscreen = nil
        showNextFullscreen()
    }

    private func markDismissed(_ id: String) {
        var ids = dismissedIDs
        ids.insert(id)
        dismissedIDs = ids
    }

    func resetDismissed() {
        UserDefaults.standard.removeObject(forKey: dismissedKey)
        recurringCampaignIdsInFlight.removeAll()
        UserDefaults.standard.removeObject(forKey: AnnouncementFetchKeys.coldLaunchImpressionsJSON)
    }
}
