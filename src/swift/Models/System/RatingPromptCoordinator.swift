// SPDX-License-Identifier: GPL-3.0+

import Foundation
import StoreKit
import SwiftUI
import UIKit

// Custom rating-prompt flow.
//
// Flow (per product spec):
// 1. After exiting a game played for >= 10 minutes, ask the user (in our own UI)
//    if they want to rate the app.
// 2. If the user taps "No", we never present Apple's SKStoreReviewController.
//    We then wait until the 6th completed game session and ask again.
// 3. If the user taps "No" the second time, wait 30 days, then ask again on
//    the next eligible (>= 10 min) session end. Repeat until accepted.
// 4. If the user taps "Yes", we mark accepted and call SKStoreReviewController
//    which surfaces Apple's standard rating sheet. We never ask again.

@Observable
final class RatingPromptCoordinator: @unchecked Sendable {
    static let shared = RatingPromptCoordinator()

    enum Stage: Int {
        case initial = 0
        case declinedOnce = 1
        case declinedAgain = 2
        case accepted = 3
    }

    // Minimum elapsed playtime (seconds) for the just-ended session to qualify.
    static let minSessionSeconds: TimeInterval = 10 * 60
    // After first decline, wait this many additional completed sessions.
    static let gamesAfterFirstDecline: Int = 6
    // After second (and subsequent) decline, wait this many days.
    static let daysAfterSecondDecline: TimeInterval = 30 * 24 * 60 * 60

    // Persisted keys.
    private let stageKey = "Sakura.Rating.Stage"
    private let gamesPlayedKey = "Sakura.Rating.GamesPlayed"
    private let gamesAtFirstDeclineKey = "Sakura.Rating.GamesAtFirstDecline"
    private let lastDeclinedAtKey = "Sakura.Rating.LastDeclinedAt"

    private let defaults = UserDefaults.standard

    // visible state. drives the SwiftUI overlay.
    var isPromptVisible: Bool = false

    private init() {}

    // MARK: - Persistence helpers

    private var stage: Stage {
        get { Stage(rawValue: defaults.integer(forKey: stageKey)) ?? .initial }
        set { defaults.set(newValue.rawValue, forKey: stageKey) }
    }

    private var gamesPlayed: Int {
        get { defaults.integer(forKey: gamesPlayedKey) }
        set { defaults.set(newValue, forKey: gamesPlayedKey) }
    }

    private var gamesAtFirstDecline: Int {
        get { defaults.integer(forKey: gamesAtFirstDeclineKey) }
        set { defaults.set(newValue, forKey: gamesAtFirstDeclineKey) }
    }

    private var lastDeclinedAt: Date? {
        get {
            let ts = defaults.double(forKey: lastDeclinedAtKey)
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        set {
            if let v = newValue {
                defaults.set(v.timeIntervalSince1970, forKey: lastDeclinedAtKey)
            } else {
                defaults.removeObject(forKey: lastDeclinedAtKey)
            }
        }
    }

    // MARK: - Public entry point

    /// Called by `AppState` when a game session shuts down.
    /// `elapsed` is the duration of the just-ended session in seconds.
    @MainActor
    func sessionDidEnd(elapsed: TimeInterval) {
        // Always count completed sessions. Anything that ran for at least one
        // second counts as a "game played".
        guard elapsed > 1 else { return }
        gamesPlayed &+= 1

        guard stage != .accepted else { return }
        guard !isPromptVisible else { return }
        guard elapsed >= Self.minSessionSeconds else { return }

        if shouldPromptNow() {
            // Tiny delay so the menu has time to settle on screen first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                guard self.stage != .accepted, !self.isPromptVisible else { return }
                self.isPromptVisible = true
            }
        }
    }

    private func shouldPromptNow() -> Bool {
        switch stage {
        case .initial:
            return true
        case .declinedOnce:
            return (gamesPlayed - gamesAtFirstDecline) >= Self.gamesAfterFirstDecline
        case .declinedAgain:
            guard let last = lastDeclinedAt else { return true }
            return Date().timeIntervalSince(last) >= Self.daysAfterSecondDecline
        case .accepted:
            return false
        }
    }

    // MARK: - User responses

    @MainActor
    func userTappedYes() {
        isPromptVisible = false
        stage = .accepted
        presentAppleReviewController()
    }

    @MainActor
    func userTappedNo() {
        isPromptVisible = false
        switch stage {
        case .initial:
            stage = .declinedOnce
            gamesAtFirstDecline = gamesPlayed
        case .declinedOnce:
            stage = .declinedAgain
            lastDeclinedAt = Date()
        case .declinedAgain:
            // Reset the 30-day clock.
            lastDeclinedAt = Date()
        case .accepted:
            break
        }
    }

    // MARK: - Apple sheet

    @MainActor
    private func presentAppleReviewController() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
        else { return }
        SKStoreReviewController.requestReview(in: scene)
    }
}
