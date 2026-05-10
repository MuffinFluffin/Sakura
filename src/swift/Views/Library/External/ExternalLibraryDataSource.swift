// SPDX-License-Identifier: GPL-3.0+

import Combine
import Foundation
import SwiftUI
import UIKit

/// Owns the AirConsole library's game list, cover/info fetch jobs, and per-game clip
/// lookups so the external shell does not duplicate handheld plumbing.
///
/// Mirrors `LibraryShell.refreshLibrary` semantics but exposes Combine publishes so
/// SwiftUI views can react via `@StateObject`.
@MainActor
final class ExternalLibraryDataSource: ObservableObject {
    static let shared = ExternalLibraryDataSource()

    @Published private(set) var games: [GameItem] = []
    @Published private(set) var loadVersion: Int = 0

    private var fingerprint: UInt64 = 0
    private var ticket: UInt = 0
    private var coverFetchInFlight: Set<String> = []
    private var infoFetchInFlight: Set<String> = []

    private init() {}

    func refresh(force: Bool = false) {
        let gamesDir = SakuraBridge.isoDirectory()
        let docsDir = SakuraBridge.documentsDirectory()
        let fileNames = SakuraBridge.availableISOs()
        let emulationIsRunning = SakuraBridge.isEmulationRunning()
        let mapFp = sakuraISOListingFingerprint(
            names: fileNames,
            emulationStoppedForMapping: !emulationIsRunning
        )
        if !force, !games.isEmpty, mapFp == fingerprint { return }

        ticket &+= 1
        let myTicket = ticket

        Task {
            let mapped = await Task.detached(priority: .utility) {
                LibraryShell.mappedLibraryItems(
                    fileNames: fileNames,
                    gamesDir: gamesDir,
                    docsDir: docsDir,
                    emulationIsRunning: emulationIsRunning
                )
            }.value
            await MainActor.run {
                guard myTicket == self.ticket else { return }
                self.fingerprint = mapFp
                self.games = sakuraDeduplicatedLibraryGames(mapped).sorted { a, b in
                    if a.isFavorite != b.isFavorite { return a.isFavorite }
                    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
                self.loadVersion &+= 1

                if !emulationIsRunning {
                    self.kickPendingMetadataFetches()
                }
            }
        }
    }

    func setFavorite(_ name: String, favorite: Bool) {
        SakuraBridge.setFavorite(name, favorite: favorite)
        refresh(force: true)
    }

    private func kickPendingMetadataFetches() {
        for game in games {
            scheduleCoverFetchIfNeeded(for: game)
            scheduleInfoFetchIfNeeded(for: game)
        }
    }

    private func scheduleCoverFetchIfNeeded(for game: GameItem) {
        guard game.imagePath == nil else { return }
        if let serial = game.gameID, !serial.isEmpty {
            guard !coverFetchInFlight.contains(serial) else { return }
            coverFetchInFlight.insert(serial)
            GameMetadataService.shared.fetchCover(forSerial: serial) { fetched in
                DispatchQueue.main.async {
                    self.coverFetchInFlight.remove(serial)
                    guard let fetched else { return }
                    self.applyFetchedCover(fileName: game.fileName, serial: serial, path: fetched)
                }
            }
            return
        }
        let key = game.metadataKey
        guard !key.isEmpty, !coverFetchInFlight.contains(key) else { return }
        coverFetchInFlight.insert(key)
        GameMetadataService.shared.fetchCover(forCacheKey: key, title: game.title) { fetched in
            DispatchQueue.main.async {
                self.coverFetchInFlight.remove(key)
                guard let fetched else { return }
                self.applyFetchedCover(fileName: game.fileName, serial: key, path: fetched)
            }
        }
    }

    private func applyFetchedCover(fileName: String, serial: String, path: String) {
        guard let idx = games.firstIndex(where: { $0.fileName == fileName }) else { return }
        var updated = games[idx]
        updated.imagePath = GameMetadataService.shared.cachedUpscaledCoverPath(forSerial: serial) ?? path
        games[idx] = updated
        loadVersion &+= 1
    }

    private func scheduleInfoFetchIfNeeded(for game: GameItem) {
        let needsInfo = (game.releaseDate == "Unknown" && game.genre == "Unknown"
            && game.developer == "Unknown" && game.publisher == "Unknown")
        guard needsInfo else { return }
        let key = game.metadataKey
        guard !key.isEmpty, !infoFetchInFlight.contains(key) else { return }
        infoFetchInFlight.insert(key)
        GameMetadataService.shared.fetchInfo(forSerial: key, title: game.title) { info in
            DispatchQueue.main.async {
                self.infoFetchInFlight.remove(key)
                guard let info,
                      let idx = self.games.firstIndex(where: { $0.fileName == game.fileName })
                else { return }
                var updated = self.games[idx]
                if !info.title.isEmpty { updated.title = info.title }
                updated.releaseDate = info.releaseDate
                updated.genre = info.genre
                updated.developer = info.developer
                updated.publisher = info.publisher
                updated.summary = info.summary
                self.games[idx] = updated
                self.loadVersion &+= 1
            }
        }
    }
}

/// Per-game media filtering. Keeps the matching logic in one place so the clips strip
/// does not have to know about `MediaSidecar` field formats.
enum ExternalGameMediaFilter {
    // strict ISO match. sidecar isoName must equal the game's absolute path
    // or share its filename (case insensitive). avoids cross-game leakage.
    static func belongsTo(item: MediaItem, game: GameItem) -> Bool {
        guard item.kind == .recording || item.kind == .screenshot else { return false }
        guard let isoName = item.sidecar?.isoName, !isoName.isEmpty else { return false }
        if isoName.caseInsensitiveCompare(game.absolutePath ?? "") == .orderedSame { return true }
        let leaf = (isoName as NSString).lastPathComponent
        if leaf.caseInsensitiveCompare(game.fileName) == .orderedSame { return true }
        let gameLeaf = (game.absolutePath as NSString?)?.lastPathComponent
        if let gameLeaf, leaf.caseInsensitiveCompare(gameLeaf) == .orderedSame { return true }
        return false
    }

    /// Most recent recording first, then a deterministic shuffle of the remaining
    /// items so the strip does not flicker on every redraw. Cap at `maxCount`.
    static func clipsForGame(_ game: GameItem, all items: [MediaItem], maxCount: Int = 5) -> [MediaItem] {
        let owned = items.filter { belongsTo(item: $0, game: game) }
        guard !owned.isEmpty else { return [] }

        let recordings = owned.filter { $0.kind == .recording }.sorted { $0.modified > $1.modified }
        var ordered: [MediaItem] = []
        if let latest = recordings.first { ordered.append(latest) }

        let remaining = owned.filter { $0.url != ordered.first?.url }
        let recordingsRest = remaining.filter { $0.kind == .recording }
        let screenshots = remaining.filter { $0.kind == .screenshot }
        let pool = recordingsRest + screenshots

        var seed = UInt64(truncatingIfNeeded: game.fileName.hashValue)
        if seed == 0 { seed = 0x9e3779b97f4a7c15 }
        let shuffled = deterministicShuffle(pool, seed: seed)
        for item in shuffled where ordered.count < maxCount {
            ordered.append(item)
        }
        return ordered
    }

    private static func deterministicShuffle(_ items: [MediaItem], seed: UInt64) -> [MediaItem] {
        var arr = items
        var s = seed == 0 ? 0x9e3779b97f4a7c15 : seed
        for i in stride(from: arr.count - 1, through: 1, by: -1) {
            s ^= s &<< 13
            s ^= s &>> 7
            s ^= s &<< 17
            let j = Int(s % UInt64(i + 1))
            arr.swapAt(i, j)
        }
        return arr
    }
}
