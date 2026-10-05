import Foundation

/// Bounded, persisted, FIFO event queue.
///
/// Design notes that matter, mirrored in every other SDK:
///
///  - **Written before the send is attempted.** A crash mid-flush loses nothing; the worst
///    case is a duplicate, which the server dedupes on `(install_id, event_id)`. The queue
///    is the durability boundary, not the transport.
///  - **Bounded.** 500 events / 30 days. Unbounded queueing on a device with no network is
///    how an SDK becomes the largest thing in the app's storage and gets flagged in review.
///  - **Drops are counted, not hidden.** `droppedCount` rides along on the next successful
///    request so the dashboard can show partial attribution instead of silently
///    under-reporting conversions.

public struct QueuedEvent: Codable, Sendable, Equatable {
    /// Client-generated UUID v4. Doubles as the `order.id` on the wire.
    public var eventId: String
    public var name: String
    public var occurredAt: String
    ///
    /// Required, because `order` is required on the unified payload and `order.id` is its
    /// only required key: the SDK mints a UUID for a bare event, or stores the host app's
    /// full order for a purchase.
    public var order: Order
    /// Set once the event has been handed to the transport at least once.
    public var attempts: Int?

    public init(eventId: String, name: String, occurredAt: String, order: Order, attempts: Int? = nil) {
        self.eventId = eventId
        self.name = name
        self.occurredAt = occurredAt
        self.order = order
        self.attempts = attempts
    }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case name
        case occurredAt = "occurred_at"
        case order
        case attempts
    }
}

/// A minimal `Any`-like Codable box for event properties.
///
/// Needed because `[String: Any]` is not `Codable`. Handles the JSON types the protocol
/// permits; anything else is encoded via its `String(describing:)` so a caller passing an
/// exotic object degrades to a readable string instead of throwing and losing the event.
public enum AnyCodableValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([AnyCodableValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    /// Boxes an `Any` from host-app code.
    public static func box(_ value: Any) -> AnyCodableValue {
        switch value {
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as Float: return .double(Double(v))
        case let v as NSNumber:
            // `NSNumber` erases Bool/Int/Double distinctions; check the ObjC type code.
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            if v.doubleValue == v.doubleValue.rounded() && abs(v.doubleValue) < Double(Int.max) {
                return .int(v.intValue)
            }
            return .double(v.doubleValue)
        case let v as [Any]: return .array(v.map(box))
        case let v as [String: Any]: return .dictionary(v.mapValues(box))
        case Optional<Any>.none, is NSNull: return .null
        default: return .string(String(describing: value))
        }
    }
}

public final class EventQueue: @unchecked Sendable {
    public static let maxSize = 500
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60 // 30 days

    private struct QueueFile: Codable {
        var version: Int = 1
        var events: [QueuedEvent] = []
        var droppedCount: Int = 0
    }

    private let store: KeyValueStore
    private let now: () -> Date
    private let maxSize: Int
    private let maxAge: TimeInterval

    /// Serialises every mutation. Without this, two concurrent `logEvent` calls can both
    /// read the same array, each append, and the second write silently discards the first.
    private let lock = NSRecursiveLock()
    private var state: QueueFile?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        store: KeyValueStore,
        now: @escaping () -> Date = Date.init,
        maxSize: Int = EventQueue.maxSize,
        maxAge: TimeInterval = EventQueue.maxAge
    ) {
        self.store = store
        self.now = now
        self.maxSize = maxSize
        self.maxAge = maxAge
    }

    private func loadLocked() -> QueueFile {
        if let state { return state }

        guard let raw = store.get(StoreKeys.queue), let data = raw.data(using: .utf8) else {
            let empty = QueueFile()
            state = empty
            return empty
        }

        do {
            var parsed = try decoder.decode(QueueFile.self, from: data)
            parsed.events = parsed.events.filter { event in
                guard let date = GoAffProTimestampFormatter.date(from: event.occurredAt) else {
                    return false
                }
                return date >= now().addingTimeInterval(-maxAge)
            }
            state = parsed
            return parsed
        } catch {
            // A corrupt queue is not worth failing over. Drop it and carry on; the
            // alternative is an SDK that is permanently wedged for one user.
            let empty = QueueFile()
            state = empty
            return empty
        }
    }

    private func persistLocked(_ file: QueueFile) {
        state = file
        guard let data = try? encoder.encode(file) else { return }
        store.set(StoreKeys.queue, String(decoding: data, as: UTF8.self))
    }

    public func enqueue(_ event: QueuedEvent) {
        lock.lock(); defer { lock.unlock() }

        var file = loadLocked()
        file.events.append(event)

        if file.events.count > maxSize {
            let overflow = file.events.count - maxSize
            // Drop oldest first: they are the least likely to still be within the lookback
            // window, and dropping newest would lose the events most likely to convert.
            file.events.removeFirst(overflow)
            file.droppedCount += overflow
        }

        persistLocked(file)
    }

    /// Oldest-first slice of up to `count` events, without mutating the queue.
    public func peek(_ count: Int) -> [QueuedEvent] {
        lock.lock(); defer { lock.unlock() }
        return Array(loadLocked().events.prefix(count))
    }

    public var size: Int {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().events.count
    }

    public var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().droppedCount
    }

    /// Removes the given events. Called only after a `2xx`, which is what makes retry safe:
    /// a failed send leaves the events in place.
    public func remove(eventIds: [String]) {
        guard !eventIds.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }

        var file = loadLocked()
        let drop = Set(eventIds)
        file.events.removeAll { drop.contains($0.eventId) }
        persistLocked(file)
    }

    /// Records a failed attempt so the transport can track per-event retry counts.
    public func markAttempted(eventIds: [String]) {
        guard !eventIds.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }

        var file = loadLocked()
        let bump = Set(eventIds)
        for index in file.events.indices where bump.contains(file.events[index].eventId) {
            file.events[index].attempts = (file.events[index].attempts ?? 0) + 1
        }
        persistLocked(file)
    }

    /// Clears the queue. Used by `logout()` and when tracking is disabled.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        persistLocked(QueueFile())
    }

    /// Returns and resets the dropped counter, for inclusion on the next successful request.
    ///
    /// Reset-on-read is deliberate: the number is a *delta since last report*, and leaving it
    /// latched would report the same loss on every subsequent batch forever.
    public func takeDroppedCount() -> Int {
        lock.lock(); defer { lock.unlock() }

        var file = loadLocked()
        let count = file.droppedCount
        file.droppedCount = 0
        persistLocked(file)
        return count
    }
}
