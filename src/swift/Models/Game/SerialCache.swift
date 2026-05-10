import Foundation

final class SerialCache: @unchecked Sendable {
    enum LookupResult: Equatable {
        case absent
        case hit(String)
    }

    static let shared = SerialCache()

    private let lock = NSLock()
    private var map: [String: String] = [:]
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Sakura", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library_serial_identity.plist", isDirectory: false)
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let d = obj as? [String: String] {
            map = d
        }
    }

    private func persistLocked() {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: map, format: .binary, options: 0) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func lookup(identityCacheKey key: String) -> LookupResult {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = map[key] else { return .absent }
        return .hit(stored)
    }

    func storeBatchUnsafe(_ additions: [String: String]) {
        guard !additions.isEmpty else { return }
        lock.lock()
        for (k, v) in additions { map[k] = v }
        persistLocked()
        lock.unlock()
    }
}
