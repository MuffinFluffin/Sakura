// SPDX-License-Identifier: GPL-3.0+

import Foundation
import SwiftUI
import Observation

@Observable
@MainActor
final class SakuraNotificationCenter {
    static let shared = SakuraNotificationCenter()

    enum Kind: Equatable {
        case info
        case success
        case warning
        case error
        case controller(connected: Bool, name: String)
        case saveState(status: String)
        case music(trackTitle: String)
        case gameImported(title: String)
        case biosMissing
        case themeChanged(setting: String)
        case settingChanged(title: String, detail: String?)
    }

    struct Card: Identifiable, Equatable {
        let id: UUID
        let kind: Kind
        let title: String
        let subtitle: String?
        let icon: String
        let tintKey: String?
        let introSeconds: Int
        let persistence: TimeInterval
        let recurrence: TimeInterval
        let repeatRemaining: UInt
        let manifestAnnouncementId: String?
        let timedDismissEraseManifestDismissedState: Bool

        init(
            id: UUID = UUID(),
            kind: Kind,
            title: String,
            subtitle: String?,
            icon: String,
            tintKey: String?,
            introSeconds: Int = 3,
            persistence: TimeInterval,
            recurrence: TimeInterval = 0,
            repeatRemaining: UInt = 0,
            manifestAnnouncementId: String? = nil,
            timedDismissEraseManifestDismissedState: Bool = true
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.tintKey = tintKey
            self.introSeconds = max(0, introSeconds)
            self.persistence = persistence
            self.recurrence = recurrence
            self.repeatRemaining = repeatRemaining
            self.manifestAnnouncementId = manifestAnnouncementId
            self.timedDismissEraseManifestDismissedState = timedDismissEraseManifestDismissedState
        }

        func nextRecurrenceClone() -> Card? {
            guard repeatRemaining > 0 else { return nil }
            return Card(
                id: UUID(),
                kind: kind,
                title: title,
                subtitle: subtitle,
                icon: icon,
                tintKey: tintKey,
                introSeconds: introSeconds,
                persistence: persistence,
                recurrence: recurrence,
                repeatRemaining: repeatRemaining - 1,
                manifestAnnouncementId: manifestAnnouncementId,
                timedDismissEraseManifestDismissedState: timedDismissEraseManifestDismissedState
            )
        }
    }

    private(set) var cards: [Card] = []
    private(set) var activeFullscreenCard: Card? = nil

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }

    var positionKey: String {
        didSet { UserDefaults.standard.set(positionKey, forKey: Keys.position) }
    }

    var maxVisible: Int {
        didSet {
            let clamped = max(1, min(4, maxVisible))
            if clamped != maxVisible {
                maxVisible = clamped
            } else {
                UserDefaults.standard.set(clamped, forKey: Keys.maxVisible)
            }
        }
    }

    var defaultDuration: TimeInterval {
        didSet { UserDefaults.standard.set(defaultDuration, forKey: Keys.duration) }
    }

    var eventController: Bool {
        didSet { UserDefaults.standard.set(eventController, forKey: Keys.evtController) }
    }
    var eventSaveState: Bool {
        didSet { UserDefaults.standard.set(eventSaveState, forKey: Keys.evtSave) }
    }
    var eventMusic: Bool {
        didSet { UserDefaults.standard.set(eventMusic, forKey: Keys.evtMusic) }
    }
    var eventImport: Bool {
        didSet { UserDefaults.standard.set(eventImport, forKey: Keys.evtImport) }
    }
    var eventBIOS: Bool {
        didSet { UserDefaults.standard.set(eventBIOS, forKey: Keys.evtBIOS) }
    }
    var eventSettings: Bool {
        didSet { UserDefaults.standard.set(eventSettings, forKey: Keys.evtSettings) }
    }

    private init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
        }
        self.enabled         = bool(Keys.enabled, true)
        self.positionKey     = d.string(forKey: Keys.position) ?? "topTrailing"
        self.maxVisible      = {
            let raw = d.object(forKey: Keys.maxVisible) == nil ? 3 : d.integer(forKey: Keys.maxVisible)
            return max(1, min(4, raw))
        }()
        self.defaultDuration = {
            let v = d.double(forKey: Keys.duration)
            return v <= 0 ? 3.0 : v
        }()
        self.eventController = bool(Keys.evtController, true)
        self.eventSaveState  = bool(Keys.evtSave, true)
        self.eventMusic      = bool(Keys.evtMusic, true)
        self.eventImport     = bool(Keys.evtImport, true)
        self.eventBIOS       = bool(Keys.evtBIOS, true)
        self.eventSettings   = bool(Keys.evtSettings, true)
    }

    // MARK: - Convenience posters

    func postSettingChange(title: String, detail: String? = nil) {
        post(.settingChanged(title: title, detail: detail))
    }

    func post(_ kind: Kind) {
        guard enabled else { return }
        guard shouldShow(kind) else { return }
        let card = makeCard(for: kind)
        push(card)
    }

    func pushRaw(_ card: Card) {
        guard enabled else { return }
        push(card)
    }

    func dismiss(id: UUID) {
        if let card = cards.first(where: { $0.id == id }), let aid = card.manifestAnnouncementId {
            AnnouncementManager.shared.userDismissedManifestAnnouncement(id: aid)
        }
        cards.removeAll { $0.id == id }
    }

    func presentFullscreen(_ card: Card) {
        activeFullscreenCard = card
    }

    func dismissFullscreenCard() {
        activeFullscreenCard = nil
    }

    private func expireTimedDismiss(id: UUID) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        let card = cards[idx]
        cards.remove(at: idx)
        if let next = card.nextRecurrenceClone() {
            scheduleRecurrencePush(after: card, next: next)
        } else if let aid = card.manifestAnnouncementId {
            AnnouncementManager.shared.timedDismissFinishedForManifestAnnouncement(
                id: aid,
                shouldEraseDismissedManifestEntry: card.timedDismissEraseManifestDismissedState
            )
        }
    }

    // MARK: - Private

    private func shouldShow(_ kind: Kind) -> Bool {
        switch kind {
        case .controller:     return eventController
        case .saveState:      return eventSaveState
        case .music:          return eventMusic
        case .gameImported:   return eventImport
        case .biosMissing:    return eventBIOS
        case .settingChanged: return eventSettings
        case .info, .success, .warning, .error, .themeChanged: return true
        }
    }

    private func push(_ card: Card) {
        cards.append(card)
        if cards.count > maxVisible {
            cards.removeFirst(cards.count - maxVisible)
        }
        guard card.persistence > 0 || card.repeatRemaining > 0 || card.introSeconds > 0 else { return }
        var delay: TimeInterval
        if card.persistence > 0 {
            delay = TimeInterval(card.introSeconds) + card.persistence
        } else if card.repeatRemaining > 0 {
            delay = TimeInterval(card.introSeconds)
            if delay <= 0 { delay = 0.05 }
        } else {
            delay = TimeInterval(card.introSeconds)
            if delay <= 0 { return }
        }
        let cardId = card.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self?.expireTimedDismiss(id: cardId)
            }
        }
    }

    private func scheduleRecurrencePush(after finished: Card, next: Card) {
        let gap = max(0, finished.recurrence)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            await MainActor.run {
                guard let self, self.enabled else { return }
                self.push(next)
            }
        }
    }

    private func makeCard(for kind: Kind) -> Card {
        let dur = defaultDuration
        switch kind {
        case .info:
            return Card(kind: .info, title: SakuraL10n.tr("notif.card.info"), subtitle: nil,
                        icon: "info.circle.fill", tintKey: nil, introSeconds: 0, persistence: dur)
        case .success:
            return Card(kind: .success, title: SakuraL10n.tr("notif.card.success"), subtitle: nil,
                        icon: "checkmark.seal.fill", tintKey: "green", introSeconds: 0, persistence: dur)
        case .warning:
            return Card(kind: .warning, title: SakuraL10n.tr("notif.card.warning"), subtitle: nil,
                        icon: "exclamationmark.triangle.fill", tintKey: "amber", introSeconds: 0, persistence: dur)
        case .error:
            return Card(kind: .error, title: SakuraL10n.tr("notif.card.error"), subtitle: nil,
                        icon: "xmark.octagon.fill", tintKey: "red", introSeconds: 0, persistence: dur)
        case .controller(let connected, let name):
            return Card(
                kind: kind,
                title: connected ? SakuraL10n.tr("notif.card.controllerConnected") : SakuraL10n.tr("notif.card.controllerDisconnected"),
                subtitle: name.isEmpty ? nil : name,
                icon: connected ? "gamecontroller.fill" : "gamecontroller",
                tintKey: nil,
                introSeconds: 0,
                persistence: dur
            )
        case .saveState(let status):
            return Card(kind: kind, title: SakuraL10n.tr("notif.card.saveState"), subtitle: status,
                        icon: "sdcard.fill", tintKey: nil, introSeconds: 0, persistence: dur)
        case .music(let track):
            return Card(kind: kind, title: SakuraL10n.tr("notif.card.nowPlaying"), subtitle: track,
                        icon: "music.note", tintKey: nil, introSeconds: 0, persistence: 1.5)
        case .gameImported(let title):
            return Card(kind: kind, title: SakuraL10n.tr("notif.card.importComplete"), subtitle: title,
                        icon: "tray.and.arrow.down.fill", tintKey: "green",
                        introSeconds: 0,
                        persistence: dur)
        case .biosMissing:
            return Card(kind: kind, title: SakuraL10n.tr("notif.card.biosRequired"),
                        subtitle: SakuraL10n.tr("notif.card.biosRequiredSubtitle"),
                        icon: "exclamationmark.octagon", tintKey: "amber",
                        introSeconds: 0,
                        persistence: 5)
        case .themeChanged(let l10nKey):
            return Card(kind: kind, title: SakuraL10n.tr("notif.card.themeUpdated"),
                        subtitle: SakuraL10n.tr(l10nKey),
                        icon: "paintbrush.fill", tintKey: nil,
                        introSeconds: 0,
                        persistence: 1.5)
        case .settingChanged(let name, let detail):
            return Card(kind: kind, title: name,
                        subtitle: detail,
                        icon: "gearshape.fill", tintKey: nil,
                        introSeconds: 0,
                        persistence: dur)
        }
    }

    // MARK: - Settings keys

    private enum Keys {
        static let enabled = "sakura.notif.enabled"
        static let position = "sakura.notif.position"
        static let maxVisible = "sakura.notif.maxVisible"
        static let duration = "sakura.notif.duration"
        static let evtController = "sakura.notif.evt.controller"
        static let evtSave = "sakura.notif.evt.saveState"
        static let evtMusic = "sakura.notif.evt.music"
        static let evtImport = "sakura.notif.evt.import"
        static let evtBIOS = "sakura.notif.evt.bios"
        static let evtSettings = "sakura.notif.evt.settings"
    }
}
