import Foundation

/// Payload builders.
///
/// This is the file that must stay in lockstep with `packages/protocol/spec.md`, and whose
/// output is asserted against `packages/protocol/fixtures`.
///
/// The rule it enforces everywhere: **omit optional fields entirely rather than sending
/// `null`**. The server treats an explicit `null` as "the app asserted there is no value",
/// which is a different (and wrong) claim from "the app could not observe a value".
///
/// All five endpoints (`/v1/install`, `/v1/deep-link`, `/v1/referral-code`, `/v1/event`,
/// `/v1/identify`) take the SAME body, built by `unified(event:...)` below. Only the `event`
/// discriminator distinguishes them.
///
/// Implemented with an ordered dictionary rather than `Codable` structs on purpose: key
/// order in the fixture diff is irrelevant, but *presence* is not, and hand-rolled structs
/// with `encodeIfPresent` make accidental `null`s easy to introduce and hard to spot. Here
/// the `put` helper is the single place that decides presence.

/// A JSON value we build by hand so presence is explicit.
public enum JSONValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object(JSONObject)
    case null
}

/// An insertion-ordered JSON object with presence-aware helpers.
///
/// `Sendable` because instances cross into the transport's async context; it is safe
/// because the storage is a value type with no shared reference semantics.
public struct JSONObject: Sendable {
    private var storage: [(String, JSONValue)] = []

    public init() {}

    /// Inserts a key only when the value is non-nil. This is the mechanism that keeps
    /// optional-but-absent fields absent on the wire.
    @discardableResult
    public mutating func put(_ key: String, _ value: String?) -> Self {
        if let value { storage.append((key, .string(value))) }
        return self
    }

    @discardableResult
    public mutating func put(_ key: String, _ value: Int?) -> Self {
        if let value { storage.append((key, .int(value))) }
        return self
    }

    @discardableResult
    public mutating func put(_ key: String, _ value: Double?) -> Self {
        if let value { storage.append((key, .double(value))) }
        return self
    }

    @discardableResult
    public mutating func put(_ key: String, _ value: Bool?) -> Self {
        if let value { storage.append((key, .bool(value))) }
        return self
    }

    /// Explicitly inserts a JSON `null`.
    ///
    /// Used only where the protocol demands it: `install_id` on a first-launch install, and
    /// `device_token` when push is configured but no token has been issued yet. Those are
    /// *assertions of absence*, deliberately distinguishable from an omitted key.
    @discardableResult
    public mutating func putNull(_ key: String) -> Self {
        storage.append((key, .null))
        return self
    }

    @discardableResult
    public mutating func put(_ key: String, _ value: JSONValue?) -> Self {
        if let value { storage.append((key, value)) }
        return self
    }

    @discardableResult
    public mutating func put(_ key: String, object: JSONObject?) -> Self {
        if let object { storage.append((key, .object(object))) }
        return self
    }

    @discardableResult
    public mutating func put(_ key: String, array: [JSONValue]?) -> Self {
        if let array { storage.append((key, .array(array))) }
        return self
    }

    /// Encodes to compact, key-ordered JSON — the exact bytes that go on the wire.
    public func jsonString() -> String {
        var out = "{"
        var first = true
        for (key, value) in storage {
            if !first { out += "," }
            first = false
            out += "\"\(escape(key))\":"
            out += value.jsonString()
        }
        out += "}"
        return out
    }

    /// Serialises to a `[String: Any]` for tests and for `JSONSerialization` comparison
    /// against the golden fixtures.
    public func jsonObject() -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in storage { out[key] = value.anyValue() }
        return out
    }

    /// Read access by key, for internal decoding of server responses.
    public subscript(key: String) -> JSONValue? {
        storage.first { $0.0 == key }?.1
    }

    /// Convenience accessor returning the underlying Swift value.
    public func value(_ key: String) -> Any? {
        self[key]?.anyValue()
    }

    private func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }
}

extension JSONValue {
    func jsonString() -> String {
        switch self {
        case .string(let v): return "\"\(v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        case .int(let v): return String(v)
        case .double(let v):
            // Integers must not serialise as `2499.0` — the fixtures write `2499`, and the
            // server parses `amount` as a decimal, so trailing-zero noise is avoidable churn.
            if v == v.rounded() && abs(v) < 1e15 {
                return String(Int(v))
            }
            return String(v)
        case .bool(let v): return v ? "true" : "false"
        case .array(let v): return "[" + v.map { $0.jsonString() }.joined(separator: ",") + "]"
        case .object(let v): return v.jsonString()
        case .null: return "null"
        }
    }

    func anyValue() -> Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map { $0.anyValue() }
        case .object(let v): return v.jsonObject()
        case .null: return NSNull()
        }
    }
}

// MARK: - Builders

public enum Payloads {
    /// Wraps `data` in the common envelope.
    public static func envelope(
        sdk: SDKInfo,
        data: JSONObject,
        sentAt: Date = Date()
    ) -> JSONObject {
        var root = JSONObject()
        root.put("protocol", goAffProProtocolVersion)
        root.put("sent_at", Hashing.timestamp(sentAt))
        root.put("sdk", object: sdkObject(sdk))
        root.put("data", object: data)
        return root
    }

    public static func sdkObject(_ sdk: SDKInfo) -> JSONObject {
        var obj = JSONObject()
        obj.put("platform", sdk.platform)
        obj.put("version", sdk.version)
        return obj
    }

    public static func app(_ app: AppInfo) -> JSONObject {
        var obj = JSONObject()
        obj.put("version", app.version)
        obj.put("build", app.build)
        obj.put("bundle_id", app.bundleId)
        return obj
    }

    /// The always-present `fingerprint` object.
    ///
    /// Unlike the older `device`/`fingerprint` split, all nine keys are required by the
    /// protocol, so this never omits a key — it falls back to a neutral default. A missing
    /// timezone or model is not a reason to send an unparseable payload.
    ///
    /// `platform` is parameterised because the protocol is shared with the Android SDK.
    public static func fingerprint(_ device: DeviceInfo, platform: String = "ios") -> JSONObject {
        var obj = JSONObject()
        obj.put("platform", platform)
        obj.put("os_version", device.osVersion)
        obj.put("model", device.model ?? "unknown")
        obj.put("screen_width", Double(device.screen?.width ?? 0))
        obj.put("screen_height", Double(device.screen?.height ?? 0))
        obj.put("screen_scale", device.screen?.scale ?? 1)
        obj.put("timezone", device.timezone ?? "UTC")
        obj.put("timezoneOffset", device.timezoneOffset ?? 0)
        obj.put("locale", device.locale ?? "en")
        return obj
    }

    /// An `order`. `id` is the only required key; everything else is omitted unless supplied.
    ///
    /// For a `purchase`, `id` is the host app's own order id and is the server's dedupe key.
    /// For every other event there is no real order, so the SDK mints a UUID.
    public static func order(_ order: Order) -> JSONObject {
        var obj = JSONObject()
        obj.put("id", order.id)
        obj.put("number", order.number)
        // A string on the wire, by protocol: the final amount the customer paid.
        obj.put("total", order.total)
        obj.put("subtotal", order.subtotal)
        obj.put("discount", order.discount)
        obj.put("tax", order.tax)
        obj.put("shipping", order.shipping)
        obj.put("currency", order.currency)
        obj.put("date", order.date)

        if let customer = order.customer {
            var customerObj = JSONObject()
            customerObj.put("first_name", customer.firstName)
            customerObj.put("last_name", customer.lastName)
            customerObj.put("email", customer.email)
            customerObj.put("phone", customer.phone)
            customerObj.put("is_new_customer", customer.isNewCustomer)
            obj.put("customer", object: customerObj)
        }

        if let coupons = order.coupons {
            obj.put("coupons", array: coupons.map { .string($0) })
        }

        if let lineItems = order.lineItems {
            let items: [JSONValue] = lineItems.map { item in
                var itemObj = JSONObject()
                itemObj.put("name", item.name)
                itemObj.put("quantity", item.quantity)
                itemObj.put("price", item.price)
                itemObj.put("sku", item.sku)
                itemObj.put("product_id", item.productId)
                itemObj.put("tax", item.tax)
                itemObj.put("discount", item.discount)
                return .object(itemObj)
            }
            obj.put("line_items", array: items)
        }

        obj.put("commission", order.commission)
        obj.put("delay", order.delay)
        return obj
    }

    /// The top-level `customer`. Plain, unhashed identity — the older `email_sha256` /
    /// `sendRawIdentifiers` contract is gone. The server updates the customer automatically on
    /// every `/v1/identify` call.
    public static func unifiedCustomer(_ customer: UnifiedCustomer) -> JSONObject {
        var obj = JSONObject()
        obj.put("name", customer.name)
        obj.put("email", customer.email)
        obj.put("id", customer.id)
        return obj
    }

    /// Builds the single request body shared by `/v1/install`, `/v1/deep-link`,
    /// `/v1/referral-code`, `/v1/event` and `/v1/identify`.
    ///
    /// The `event` discriminator selects the server-side handler; the endpoint in the path is
    /// mostly a routing convenience. Only `order.id` is required inside `order`, so callers
    /// that are not reporting a purchase pass `Order(id:)` and nothing else.
    public static func unified(
        event: UnifiedEventName,
        order: Order,
        app: AppInfo,
        device: DeviceInfo,
        timestamp: Int,
        installTimestamp: Int,
        platform: String = "ios",
        installReferrer: String? = nil,
        deepLink: String? = nil,
        referralCode: String? = nil,
        customer: UnifiedCustomer? = nil
    ) -> JSONObject {
        var obj = JSONObject()
        obj.put("event", event.rawValue)
        // A string on purpose: "1", not 1, matching the protocol's `protocol_version`.
        obj.put("protocol_version", String(goAffProProtocolVersion))
        obj.put("timestamp", timestamp)
        obj.put("sdk", object: sdkObject(SDKInfo(platform: platform, version: GoAffPro.version)))
        obj.put("order", object: Payloads.order(order))
        obj.put("fingerprint", object: Payloads.fingerprint(device, platform: platform))
        obj.put("app", object: Payloads.app(app))
        obj.put("install_referrer", installReferrer)
        obj.put("install_timestamp", installTimestamp)
        obj.put("deep_link", deepLink)

        obj.put("referral_code", referralCode)
        if let customer { obj.put("customer", object: unifiedCustomer(customer)) }

        return obj
    }

    static func object(from properties: [String: AnyCodableValue]) -> JSONObject {
        var obj = JSONObject()
        for key in properties.keys.sorted() {
            obj.put(key, convert(properties[key]!))
        }
        return obj
    }

    static func convert(_ value: AnyCodableValue) -> JSONValue {
        switch value {
        case .string(let v): return .string(v)
        case .int(let v): return .int(v)
        case .double(let v): return .double(v)
        case .bool(let v): return .bool(v)
        case .array(let v): return .array(v.map(convert))
        case .dictionary(let v): return .object(object(from: v))
        case .null: return .null
        }
    }
}
