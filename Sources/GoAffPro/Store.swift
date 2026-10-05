import Foundation

/// Persistence abstraction.
///
/// The SDK does not assume a specific storage backend — a host app may want the install id
/// in its own encrypted store, or in a shared app group. So the store is a protocol with a
/// sensible default and an escape hatch.

public protocol KeyValueStore: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
}

public enum StoreKeys {
    public static let installId = "gap.install_id"
    public static let queue = "gap.queue"
    public static let config = "gap.config"
    public static let activated = "gap.activated_at"
    public static let trackingEnabled = "gap.tracking_enabled"
}

/// In-memory store. Used in tests, and as a last resort when the Keychain is unavailable.
///
/// Choosing this silently would be a real bug — every launch would look like a fresh
/// install — so `GoAffPro` logs a warning in debug mode if it falls back here.
public final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private var map: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    public func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        map.removeValue(forKey: key)
    }
}

/// Keychain-backed store.
///
/// The real-world observation that shaped this implementation: in the simulator (and on a
/// device with a corrupted keychain item) `SecItemAdd` returns `errSecDuplicateItem` or
/// `errSecNotAvailable`, and code that treats "read the keychain" as infallible then either
/// crashes or silently loses the install id forever. So every operation here is
/// best-effort and falls back to the in-memory store, which at least keeps one launch
/// self-consistent.
public final class KeychainStore: KeyValueStore, @unchecked Sendable {
    private let service: String
    private let fallback = MemoryStore()
    private let lock = NSLock()
    /// Set once a Keychain operation fails with an unrecoverable status, so we stop
    /// retrying on every access (which would be both slow and noisy in the logs).
    private var keychainUnavailable = false

    public init(service: String = "com.goaffpro.attribution") {
        self.service = service
    }

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }

        if keychainUnavailable { return fallback.get(key) }

        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            if status == errSecNotAvailable || status == errSecMissingEntitlement {
                keychainUnavailable = true
            }
            return fallback.get(key)
        }

        return value
    }

    public func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }

        if keychainUnavailable {
            fallback.set(key, value)
            return
        }

        guard let data = value.data(using: .utf8) else { return }
        let query = baseQuery(key)

        // Update first, then add on `errSecItemNotFound`. Doing it the other way round
        // produces a duplicate-item error on every write after the first.
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status != errSecSuccess {
            if status == errSecNotAvailable || status == errSecMissingEntitlement {
                keychainUnavailable = true
            }
            fallback.set(key, value)
        }
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }

        let query = baseQuery(key)
        let status = SecItemDelete(query as CFDictionary)

        if status != errSecSuccess && status != errSecItemNotFound {
            if status == errSecNotAvailable || status == errSecMissingEntitlement {
                keychainUnavailable = true
            }
        }
        fallback.remove(key)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// A store backed by a JSON file in Application Support.
///
/// Used for the event queue: the queue can hold hundreds of events and does not belong in
/// the Keychain, which is sized and rate-limited for secrets, not bulk data.
public final class FileStore: KeyValueStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directoryName: String = "GoAffPro") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for key: String) -> URL {
        // Keys contain dots; replace anything that is not filename-safe so a future key
        // change cannot produce a path traversal or an unwritable name.
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        // `.atomic` so a crash mid-write cannot leave a half-written queue that then fails
        // to parse on the next launch.
        try? Data(value.utf8).write(to: url(for: key), options: .atomic)
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(for: key))
    }
}

/// A store that routes keys to different backends by prefix.
///
/// This is what `GoAffPro` uses by default: the install id goes to the Keychain (it is a
/// credential-like identifier that should not sit in a plaintext file or a backup), while
/// the event queue and config cache go to a file.
public final class CompositeStore: KeyValueStore, @unchecked Sendable {
    private let secure: KeyValueStore
    private let plain: KeyValueStore
    private let secureKeys: Set<String>

    public init(
        secure: KeyValueStore = KeychainStore(),
        plain: KeyValueStore = FileStore(),
        secureKeys: Set<String> = [StoreKeys.installId]
    ) {
        self.secure = secure
        self.plain = plain
        self.secureKeys = secureKeys
    }

    private func target(for key: String) -> KeyValueStore {
        secureKeys.contains(key) ? secure : plain
    }

    public func get(_ key: String) -> String? { target(for: key).get(key) }
    public func set(_ key: String, _ value: String) { target(for: key).set(key, value) }
    public func remove(_ key: String) { target(for: key).remove(key) }
}
