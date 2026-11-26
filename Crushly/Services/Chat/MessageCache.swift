import Foundation

/// A message that hasn't been confirmed by the server yet. Its `id` is the client message id: retries reuse it, so the
/// server can never store the same message twice.
nonisolated struct PendingMessage: Identifiable, Codable, Equatable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case sending, failed }
    var id: UUID
    var body: String
    var createdAt: Date
    var state: State
    var replyTo: ReplyPreview? = nil
}

/// On-device cache of conversations (docs/CAMPUS_SPACES_DESIGN.md §6.5).
///
/// * Files live under Application Support, written with `NSFileProtectionComplete` (unreadable while the device is
///   locked) and excluded from iCloud/iTunes backup.
/// * Purged on leave & delete, block, report, sign-out and account deletion.
/// * Never shown before `my_conversations()` has confirmed the conversation still exists (AppState enforces this).
///
/// Purging the cache can't reach screenshots, or copies on another device that is offline; the app never claims it does.
nonisolated struct CachedThread: Codable, Equatable, Sendable {
    var messages: [ChatMessage] = []
    var pending: [PendingMessage] = []
}

nonisolated final class MessageCache: @unchecked Sendable {
    let root: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(root: URL) {
        self.root = root
    }

    static func standard() -> MessageCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MessageCache(root: base.appendingPathComponent("MessageCache", isDirectory: true))
    }

    private func directory(for user: UUID) -> URL {
        root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
    }

    private func file(user: UUID, match: UUID) -> URL {
        directory(for: user).appendingPathComponent("\(match.uuidString.lowercased()).json")
    }

    private func prepare(_ dir: URL) throws {
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.complete])
        var root = self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        var dir = dir
        try? dir.setResourceValues(values)
    }

    func load(user: UUID, match: UUID) -> CachedThread? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file(user: user, match: match)) else { return nil }
        return try? JSONDecoder().decode(CachedThread.self, from: data)
    }

    func save(_ thread: CachedThread, user: UUID, match: UUID) {
        lock.lock(); defer { lock.unlock() }
        do {
            let dir = directory(for: user)
            try prepare(dir)
            let url = file(user: user, match: match)
            try JSONEncoder().encode(thread).write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            try? target.setResourceValues(values)
        } catch {
            // Best effort (e.g. the device is locked); the server stays the source of truth.
        }
    }

    func cachedMatchIDs(user: UUID) -> Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory(for: user).path)) ?? []
        return Set(names.compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) })
    }

    func purge(user: UUID, match: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: file(user: user, match: match))
    }

    /// Keeps only the listed conversations (reconciliation with `my_conversations()`).
    func purge(user: UUID, keeping: Set<UUID>) {
        for id in cachedMatchIDs(user: user) where !keeping.contains(id) { purge(user: user, match: id) }
    }

    /// Sign-out / account deletion: everything for that user goes.
    func purgeAll(user: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: directory(for: user))
    }

    /// Protection attributes of a cached file (tests verify them).
    func attributes(user: UUID, match: UUID) -> (protection: FileProtectionType?, excludedFromBackup: Bool?) {
        let url = file(user: user, match: match)
        let protection = (try? fileManager.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType
        let excluded = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        return (protection, excluded)
    }
}
