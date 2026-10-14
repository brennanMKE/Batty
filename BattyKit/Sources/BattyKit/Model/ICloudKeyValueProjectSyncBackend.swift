// ICloudKeyValueProjectSyncBackend.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ICloudKeyValueProjectSyncBackend")

/// The slice of `NSUbiquitousKeyValueStore` the backend uses, so tests drive
/// it with a fake and never reach iCloud.
@MainActor
public protocol KeyValueStoring: AnyObject {
    var dictionaryRepresentation: [String: Any] { get }
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStoring {
    public func set(_ data: Data, forKey key: String) {
        set(data as Data?, forKey: key)
    }
}

/// Stores each shared Project as one key, `project.<uuid>`, holding compact
/// JSON: a `ProjectSyncRecord`, or `{"deletedAt": ...}` for a tombstone.
@MainActor
public final class ICloudKeyValueProjectSyncBackend: ProjectSyncBackend {
    public static let keyPrefix = "project."
    /// Apple states these as "1 MB" per value and in total; the decimal
    /// reading is the conservative one.
    static let maxValueBytes = 1_000_000
    static let maxTotalBytes = 1_000_000
    static let maxKeys = 1_024
    static let tombstoneLifetime: TimeInterval = 30 * 24 * 60 * 60

    public let changes: AsyncStream<Void>
    public var onSyncError: (@MainActor (ProjectSyncError) -> Void)?
    public private(set) var lastError: ProjectSyncError?
    /// Becomes true on a server or initial-sync change and false again on an
    /// account change, so an absent key withdraws a Project only after the
    /// store has reported the account's data.
    public private(set) var snapshotIsAuthoritative = false

    private let store: any KeyValueStoring
    private let clock: @MainActor () -> Date
    private let hasEntitlement: @MainActor () -> Bool
    private let hasAccount: @MainActor () -> Bool
    private let continuation: AsyncStream<Void>.Continuation
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private let center: NotificationCenter

    public init(
        store: any KeyValueStoring = NSUbiquitousKeyValueStore.default,
        notificationCenter: NotificationCenter = .default,
        clock: @escaping @MainActor () -> Date = { Date() },
        hasEntitlement: @escaping @MainActor () -> Bool = { ProjectSyncEntitlement.isPresent() },
        hasAccount: @escaping @MainActor () -> Bool = { FileManager.default.ubiquityIdentityToken != nil }
    ) {
        self.store = store
        self.center = notificationCenter
        self.clock = clock
        self.hasEntitlement = hasEntitlement
        self.hasAccount = hasAccount
        (changes, continuation) = AsyncStream<Void>.makeStream()
        observer = notificationCenter.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: nil
        ) { [weak self] notification in
            let reason = (notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? NSNumber)?.intValue
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handleExternalChange(reason: reason, keys: keys) }
            } else {
                Task { @MainActor in self?.handleExternalChange(reason: reason, keys: keys) }
            }
        }
        store.synchronize()
        logger.info("iCloud project sync built: entitlement present \(hasEntitlement(), privacy: .public), ubiquity identity token present \(hasAccount(), privacy: .public)")
        continuation.yield()
    }

    deinit {
        if let observer { center.removeObserver(observer) }
        continuation.finish()
    }

    /// The entitlement alone: key-value storage can work while
    /// `ubiquityIdentityToken` stays nil for an app with no ubiquity container.
    public var isAvailable: Bool { hasEntitlement() }

    // MARK: - Reading

    public func snapshot() -> [UUID: ProjectSyncEntry] {
        let now = clock()
        var entries: [UUID: ProjectSyncEntry] = [:]
        for (key, value) in store.dictionaryRepresentation {
            guard let id = Self.projectID(fromKey: key) else { continue }
            guard let data = value as? Data, let entry = Self.decode(data, id: id) else {
                logger.error("skipping an undecodable shared project value")
                continue
            }
            if case .tombstone(let deletedAt) = entry, now.timeIntervalSince(deletedAt) > Self.tombstoneLifetime {
                store.removeObject(forKey: key)
                continue
            }
            entries[id] = entry
        }
        return entries
    }

    // MARK: - Writing

    public func publish(_ record: ProjectSyncRecord) throws {
        let data = try Self.encoder.encode(record)
        let key = Self.key(for: record.id)
        let stored = store.dictionaryRepresentation
        guard data.count <= Self.maxValueBytes else {
            throw ProjectSyncError.quotaExceeded(reason: .recordTooLarge)
        }
        if stored[key] == nil, stored.count + 1 > Self.maxKeys {
            throw ProjectSyncError.quotaExceeded(reason: .tooManyKeys)
        }
        let others = stored.reduce(0) { total, pair in
            guard pair.key.hasPrefix(Self.keyPrefix), pair.key != key, let value = pair.value as? Data else { return total }
            return total + value.count
        }
        guard others + data.count <= Self.maxTotalBytes else {
            throw ProjectSyncError.quotaExceeded(reason: .totalTooLarge)
        }
        store.set(data, forKey: key)
        store.synchronize()
    }

    public func withdraw(id: UUID) {
        store.removeObject(forKey: Self.key(for: id))
        store.synchronize()
    }

    public func tombstone(id: UUID, deletedAt: Date) {
        do {
            store.set(try Self.encoder.encode(Tombstone(deletedAt: deletedAt)), forKey: Self.key(for: id))
            store.synchronize()
        } catch {
            logger.error("tombstone encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - External changes

    private func handleExternalChange(reason: Int?, keys: [String]?) {
        switch reason {
        case NSUbiquitousKeyValueStoreServerChange, NSUbiquitousKeyValueStoreInitialSyncChange:
            if let keys, !keys.contains(where: { $0.hasPrefix(Self.keyPrefix) }) { return }
            store.synchronize()
            snapshotIsAuthoritative = true
            continuation.yield()
        case NSUbiquitousKeyValueStoreAccountChange:
            store.synchronize()
            snapshotIsAuthoritative = false
            continuation.yield()
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            logger.error("iCloud key-value store quota exceeded")
            let error = ProjectSyncError.quotaExceeded(reason: .totalTooLarge)
            lastError = error
            onSyncError?(error)
        default:
            break
        }
    }

    /// Test seam: ends `changes`, so a consumer's loop returns once it has
    /// handled every event yielded before this call.
    func finishChanges() {
        continuation.finish()
    }

    // MARK: - Encoding

    struct Tombstone: Codable, Equatable {
        var deletedAt: Date
    }

    static func key(for id: UUID) -> String { keyPrefix + id.uuidString }

    static func projectID(fromKey key: String) -> UUID? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(keyPrefix.count)))
    }

    static func decode(_ data: Data, id: UUID) -> ProjectSyncEntry? {
        if let record = try? decoder.decode(ProjectSyncRecord.self, from: data), record.id == id {
            return .record(record)
        }
        if let tombstone = try? decoder.decode(Tombstone.self, from: data) {
            return .tombstone(deletedAt: tombstone.deletedAt)
        }
        return nil
    }

    nonisolated private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeFormatter(fractional: true).string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = makeFormatter(fractional: true).date(from: string)
                    ?? makeFormatter(fractional: false).date(from: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid ISO 8601 date: \(string)"))
            }
            return date
        }
        return d
    }()
}
