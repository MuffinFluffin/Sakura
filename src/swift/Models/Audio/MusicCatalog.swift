// MusicCatalog.swift: music catalog with GitHub-hosted downloads.
// SPDX-License-Identifier: GPL-3.0+
//
// all music files are hosted on GitHub (MuffinFluffin/Shared-Assets) to keep
// the app binary small. SFX auto-downloads on first boot. music is opt-in
// during onboarding or via Themes > Music.

import Foundation

struct MusicTrack: Identifiable, Hashable, Codable {
    enum Source: String, Codable { case builtin, user }

    var id: String { slug }
    let slug: String
    let title: String
    let artist: String
    let source: Source
    // relative path under Documents/Music/
    let relativePath: String
    // remote download URL, nil for user-imported files.
    let remoteURL: URL?

    var localURL: URL {
        MusicCatalog.musicRoot.appendingPathComponent(relativePath)
    }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }
}

enum MusicCatalog {

    // base URL for the Shared-Assets GitHub repo (raw content).
    static let assetsBaseURL = "https://raw.githubusercontent.com/MuffinFluffin/Shared-Assets/main"

    // MARK: - Featured tracks (top picks, downloaded first during onboarding)

    // tracks shown at the top of the catalog as recommended picks. the
    // first entry is also the app's default song, used by the onboarding
    // loop and auto-selected on a fresh install.
    static let featured: [MusicTrack] = [
        .init(
            slug: "sad-relaxing-lo-fi-melody-loop-87-bpm",
            title: "Sad & Relaxing Lo-fi (87 BPM)",
            artist: "rotlily",
            source: .builtin,
            relativePath: "builtin/sad-relaxing-lo-fi-melody-loop-87-bpm.wav",
            remoteURL: URL(string: "\(assetsBaseURL)/music/sad-relaxing-lo-fi-melody-loop-87-bpm.wav")
        ),
        .init(
            slug: "butterflow-menu-music-theme",
            title: "Butterflow Menu Music Theme",
            artist: "Nomagician",
            source: .builtin,
            relativePath: "builtin/butterflow-menu-music-theme.mp3",
            remoteURL: URL(string: "\(assetsBaseURL)/music/butterflow-menu-music-theme.mp3")
        ),
        .init(
            slug: "video-game-menu-music",
            title: "Video Game Menu Music",
            artist: "magmadiverrr",
            source: .builtin,
            relativePath: "builtin/video-game-menu-music.mp3",
            remoteURL: URL(string: "\(assetsBaseURL)/music/video-game-menu-music.mp3")
        ),
    ]

    // MARK: - josefpres collection

    static let josefpres: [MusicTrack] = [
        .init(
            slug: "piano-loops-188-octave-down",
            title: "Piano Loops 188 - Octave Down",
            artist: "josefpres",
            source: .builtin,
            relativePath: "builtin/piano-loops-188-octave-down.wav",
            remoteURL: URL(string: "\(assetsBaseURL)/music/piano-loops-188-octave-down.wav")
        ),
        .init(
            slug: "piano-loops-207-efect-2-octave",
            title: "Piano Loops 207 - Efect 2 Octave",
            artist: "josefpres",
            source: .builtin,
            relativePath: "builtin/piano-loops-207-efect-2-octave.wav",
            remoteURL: URL(string: "\(assetsBaseURL)/music/piano-loops-207-efect-2-octave.wav")
        ),
        .init(
            slug: "piano-loops-201-octave-short",
            title: "Piano Loops 201 - Octave Short",
            artist: "josefpres",
            source: .builtin,
            relativePath: "builtin/piano-loops-201-octave-short.wav",
            remoteURL: URL(string: "\(assetsBaseURL)/music/piano-loops-201-octave-short.wav")
        ),
        .init(
            slug: "piano-loops-198-octave-down",
            title: "Piano Loops 198 - Octave Down",
            artist: "josefpres",
            source: .builtin,
            relativePath: "builtin/piano-loops-198-octave-down.wav",
            remoteURL: URL(string: "\(assetsBaseURL)/music/piano-loops-198-octave-down.wav")
        ),
    ]

    // MARK: - Kevin MacLeod collection

    static let kevinMacLeod: [MusicTrack] = [
        .init(
            slug: "sergios-magic-dustbin",
            title: "Sergio's Magic Dustbin",
            artist: "Kevin MacLeod",
            source: .builtin,
            relativePath: "builtin/sergios-magic-dustbin.mp3",
            remoteURL: URL(string: "\(assetsBaseURL)/music/sergios-magic-dustbin.mp3")
        ),
        .init(
            slug: "mesmerizing-galaxy",
            title: "Mesmerizing Galaxy",
            artist: "Kevin MacLeod",
            source: .builtin,
            relativePath: "builtin/mesmerizing-galaxy.mp3",
            remoteURL: URL(string: "\(assetsBaseURL)/music/mesmerizing-galaxy.mp3")
        ),
        .init(
            slug: "adventures-in-adventureland",
            title: "Adventures in Adventureland",
            artist: "Kevin MacLeod",
            source: .builtin,
            relativePath: "builtin/adventures-in-adventureland.mp3",
            remoteURL: URL(string: "\(assetsBaseURL)/music/adventures-in-adventureland.mp3")
        ),
    ]

    // all catalog tracks (featured first, then by artist).
    static var allCatalog: [MusicTrack] {
        featured + josefpres + kevinMacLeod
    }

    // Documents/Music/. created on first access.
    static var musicRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let root = docs.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("builtin"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("user"), withIntermediateDirectories: true)
        return root
    }

    // MARK: - Attribution

    static let attributionPlain =
        "Menu music by Kevin MacLeod (incompetech.com). Licensed under CC BY 4.0."

    static let attributionURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!

    static let attributionLines: [(artist: String, description: String, license: String)] = [
        ("rotlily", "Freesound.org: Sad & Relaxing Lo-fi Melody Loop (87 BPM)", "CC0 1.0"),
        ("Nomagician", "Freesound.org: Butterflow Menu Music Theme", "CC BY 4.0"),
        ("magmadiverrr", "Freesound.org: Video Game Menu Music", "CC0 1.0"),
        ("josefpres", "Freesound.org: Piano Loops 188, 198, 201, 207", "CC0 1.0"),
        ("Kevin MacLeod", "incompetech.com: Sergio's Magic Dustbin, Mesmerizing Galaxy, Adventures in Adventureland", "CC BY 4.0"),
    ]

    // MARK: - Downloader

    // download one track into Documents/Music/builtin/.
    // returns the local URL on success. network failures propagate as thrown errors.
    static func download(_ track: MusicTrack) async throws -> URL {
        guard let remote = track.remoteURL else {
            throw NSError(domain: "Sakura.Music", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No remote URL for track"
            ])
        }

        let (tmp, response) = try await URLSession.shared.download(from: remote)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Sakura.Music", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode) downloading \(track.title)"
            ])
        }

        let destination = track.localURL
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        return destination
    }

    /// Download multiple tracks concurrently. Returns (succeeded, failed) counts.
    static func downloadAll(_ tracks: [MusicTrack]) async -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0
        await withTaskGroup(of: Bool.self) { group in
            for track in tracks where !track.isDownloaded {
                group.addTask {
                    do {
                        _ = try await download(track)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await result in group {
                if result { succeeded += 1 } else { failed += 1 }
            }
        }
        return (succeeded, failed)
    }

    /// Scan `Documents/Music/user/` for user-imported audio files.
    static func importedUserTracks() -> [MusicTrack] {
        let userRoot = musicRoot.appendingPathComponent("user")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: userRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .filter { isSupportedAudio($0) }
            .map { url in
                let slug = "user-\(url.deletingPathExtension().lastPathComponent)"
                let title = url.deletingPathExtension().lastPathComponent
                return MusicTrack(
                    slug: slug,
                    title: title,
                    artist: "Imported",
                    source: .user,
                    relativePath: "user/\(url.lastPathComponent)",
                    remoteURL: nil
                )
            }
    }

    static func downloadedBuiltinTracks() -> [MusicTrack] {
        fullCatalog.filter { $0.isDownloaded }
    }

    static func isSupportedAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "m4a", "aac", "wav", "flac", "aiff", "caf"].contains(ext)
    }

    // MARK: - Live catalog (pulls new tracks from GitHub)

    private static let remoteCatalogURL = URL(string: "\(assetsBaseURL)/catalog.json")!
    private static let cachedCatalogKey = "sakura.music.remoteCatalog"

    /// Tracks discovered from the remote catalog.json that aren't already
    /// in the hardcoded catalog. Persisted in UserDefaults between launches.
    static var remoteTracks: [MusicTrack] {
        guard let data = UserDefaults.standard.data(forKey: cachedCatalogKey),
              let tracks = try? JSONDecoder().decode([MusicTrack].self, from: data)
        else { return [] }
        return tracks
    }

    /// All catalog tracks including any discovered remotely.
    static var fullCatalog: [MusicTrack] {
        let hardcoded = allCatalog
        let remote = remoteTracks.filter { rt in !hardcoded.contains(where: { $0.slug == rt.slug }) }
        return hardcoded + remote
    }

    /// Fetch catalog.json from GitHub and merge any new tracks.
    /// Returns the count of newly discovered tracks.
    @discardableResult
    static func refreshRemoteCatalog() async -> Int {
        do {
            let (data, response) = try await URLSession.shared.data(from: remoteCatalogURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return 0 }
            let manifest = try JSONDecoder().decode(RemoteCatalogManifest.self, from: data)
            let hardcodedSlugs = Set(allCatalog.map(\.slug))
            let existingSlugs = Set(remoteTracks.map(\.slug))
            let newTracks = manifest.tracks
                .map { entry in
                    MusicTrack(
                        slug: entry.slug,
                        title: entry.title,
                        artist: entry.artist,
                        source: .builtin,
                        relativePath: "builtin/\(entry.filename)",
                        remoteURL: URL(string: "\(assetsBaseURL)/music/\(entry.filename)")
                    )
                }
                .filter { !hardcodedSlugs.contains($0.slug) && !existingSlugs.contains($0.slug) }
            if !newTracks.isEmpty {
                let merged = remoteTracks + newTracks
                if let encoded = try? JSONEncoder().encode(merged) {
                    UserDefaults.standard.set(encoded, forKey: cachedCatalogKey)
                }
            }
            return newTracks.count
        } catch {
            return 0
        }
    }

    struct RemoteCatalogManifest: Codable {
        struct Entry: Codable {
            let slug: String
            let title: String
            let artist: String
            let filename: String
        }
        let tracks: [Entry]
    }
}
