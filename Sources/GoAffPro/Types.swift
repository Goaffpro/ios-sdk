import Foundation

/// Public types for the GoAffPro attribution SDK.
///
/// These mirror `packages/protocol/spec.md` exactly, and are deliberately named the same as
/// their Kotlin, Dart and TypeScript counterparts so documentation is interchangeable
/// across SDKs.

/// Wire protocol version. Must match `PROTOCOL_VERSION` in the protocol package.
public let goAffProProtocolVersion = 1

/// How attribution was decided. See the precedence table in the protocol spec.
public enum AttributionTier: String, Codable, Sendable {
    case platformReferrer = "platform_referrer"
    case probabilistic
    case referralCode = "referral_code"
    case organic
}

/// `pending` means the server has not decided yet — the install is inside the lookback
/// window and could still be matched by a later click report.
public enum AttributionStatus: String, Codable, Sendable {
    case attributed
    case pending
    case organic
}

public struct Affiliate: Codable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let code: String

    public init(id: String, name: String? = nil, code: String) {
        self.id = id
        self.name = name
        self.code = code
    }
}

public struct Campaign: Codable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let clickId: String?

    public init(id: String, name: String? = nil, clickId: String? = nil) {
        self.id = id
        self.name = name
        self.clickId = clickId
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case clickId = "click_id"
    }
}

public struct Attribution: Codable, Sendable, Equatable {
    public let status: AttributionStatus
    public let tier: AttributionTier
    /// 0...1. Only meaningful when `tier` is `.probabilistic`.
    public let confidence: Double?
    public let affiliate: Affiliate?
    public let campaign: Campaign?
    public let clickedAt: Date?

    public init(
        status: AttributionStatus,
        tier: AttributionTier,
        confidence: Double? = nil,
        affiliate: Affiliate? = nil,
        campaign: Campaign? = nil,
        clickedAt: Date? = nil
    ) {
        self.status = status
        self.tier = tier
        self.confidence = confidence
        self.affiliate = affiliate
        self.campaign = campaign
        self.clickedAt = clickedAt
    }

    enum CodingKeys: String, CodingKey {
        case status, tier, confidence, affiliate, campaign
        case clickedAt = "clicked_at"
    }
}

public struct DeepLink: Codable, Sendable, Equatable {
    public let url: String
    public let params: [String: String]
    public let fallbackUrl: String?

    public init(url: String, params: [String: String] = [:], fallbackUrl: String? = nil) {
        self.url = url
        self.params = params
        self.fallbackUrl = fallbackUrl
    }

    enum CodingKeys: String, CodingKey {
        case url, params
        case fallbackUrl = "fallback_url"
    }
}

public struct RemoteConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var eventBatchSize: Int
    public var eventFlushIntervalMs: Int
    public var sessionTimeoutMs: Int
    public var lookbackWindowHours: Int
    public var deepLinkScheme: String?
    public var universalLinkHosts: [String]?
    public var disabledEvents: [String]?

    /// Defaults used before `/v1/config` has ever succeeded. Deliberately conservative so
    /// they are always safe to ship.
    public static let `default` = RemoteConfig(
        enabled: true,
        eventBatchSize: 20,
        eventFlushIntervalMs: 30_000,
        sessionTimeoutMs: 1_800_000,
        lookbackWindowHours: 720,
        deepLinkScheme: nil,
        universalLinkHosts: nil,
        disabledEvents: nil
    )

    enum CodingKeys: String, CodingKey {
        case enabled
        case eventBatchSize = "event_batch_size"
        case eventFlushIntervalMs = "event_flush_interval_ms"
        case sessionTimeoutMs = "session_timeout_ms"
        case lookbackWindowHours = "lookback_window_hours"
        case deepLinkScheme = "deep_link_scheme"
        case universalLinkHosts = "universal_link_hosts"
        case disabledEvents = "disabled_events"
    }
}

/// Tier 1 evidence. Populated from `AdServices` / `ASA` where available, or supplied by the
/// host app.
public struct ReferrerInfo: Sendable, Equatable {
    public enum Source: String, Sendable {
        case playInstallReferrer = "play_install_referrer"
        case iosAdsAttribution = "ios_ads_attribution"
        case iosAsa = "ios_asa"
        case appStoreSearchAds = "app_store_search_ads"
    }

    public let source: Source
    public let raw: String?
    public let clickId: String?
    public let utmSource: String?
    public let utmMedium: String?
    public let utmCampaign: String?
    public let installedAt: Date?
    public let latencyMs: Int?

    public init(
        source: Source,
        raw: String? = nil,
        clickId: String? = nil,
        utmSource: String? = nil,
        utmMedium: String? = nil,
        utmCampaign: String? = nil,
        installedAt: Date? = nil,
        latencyMs: Int? = nil
    ) {
        self.source = source
        self.raw = raw
        self.clickId = clickId
        self.utmSource = utmSource
        self.utmMedium = utmMedium
        self.utmCampaign = utmCampaign
        self.installedAt = installedAt
        self.latencyMs = latencyMs
    }
}

/// Tier 2 evidence. `idfa` must only be set when the host app has already obtained ATT
/// authorisation — the SDK will never prompt on the app's behalf.
public struct Fingerprint: Sendable, Equatable {
    public var idfa: String?
    public var idfv: String?
    public var limitAdTracking: Bool?
    public var userAgent: String?
    /// Absent when push is not configured; explicitly `nil` here means "configured but no
    /// token issued yet" — the protocol treats those as different states.
    public var deviceToken: String??

    public init(
        idfa: String? = nil,
        idfv: String? = nil,
        limitAdTracking: Bool? = nil,
        userAgent: String? = nil,
        deviceToken: String?? = nil
    ) {
        self.idfa = idfa
        self.idfv = idfv
        self.limitAdTracking = limitAdTracking
        self.userAgent = userAgent
        self.deviceToken = deviceToken
    }
}

/// The five event discriminators the unified payload supports.
public enum UnifiedEventName: String, Sendable {
    case install
    case deepLink = "deep_link"
    case referral
    case purchase
    case identify
}

public struct OrderLineItem: Codable, Sendable, Equatable {
    public var name: String
    public var quantity: Double
    public var price: Double
    public var sku: String
    public var productId: String
    /// Use only if the product price already includes VAT.
    public var tax: Double?
    /// Total discount the customer received on this product.
    public var discount: Double?

    public init(
        name: String,
        quantity: Double,
        price: Double,
        sku: String,
        productId: String,
        tax: Double? = nil,
        discount: Double? = nil
    ) {
        self.name = name
        self.quantity = quantity
        self.price = price
        self.sku = sku
        self.productId = productId
        self.tax = tax
        self.discount = discount
    }
    enum CodingKeys: String, CodingKey {
        case name, quantity, price, sku, tax, discount
        case productId = "product_id"
    }

}

public struct OrderCustomer: Codable, Sendable, Equatable {
    public var firstName: String
    public var lastName: String
    public var email: String
    public var phone: String?
    public var isNewCustomer: Bool?

    public init(
        firstName: String,
        lastName: String,
        email: String,
        phone: String? = nil,
        isNewCustomer: Bool? = nil
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.isNewCustomer = isNewCustomer
    }
    enum CodingKeys: String, CodingKey {
        case phone, email
        case firstName = "first_name"
        case lastName = "last_name"
        case isNewCustomer = "is_new_customer"
    }

}

/// The `order` object on the unified payload.
///
/// **`id` is the only required key.** For a `.purchase` it is the host app's own order id and
/// is the server's dedupe key, so send it verbatim. For every other event there is no real
/// order, so the SDK mints a UUID via `Identifiers.newOrderId()`.
public struct Order: Codable, Sendable, Equatable {
    public var id: String
    public var number: String?
    /// Final amount the customer paid. A string on the wire, by protocol.
    public var total: String?
    /// Order total minus shipping and taxes.
    public var subtotal: Double?
    public var discount: Double?
    public var tax: Double?
    public var shipping: Double?
    public var currency: String?
    public var date: String?
    public var customer: OrderCustomer?
    public var coupons: [String]?
    public var lineItems: [OrderLineItem]?
    /// (Not recommended) explicit commission for this order.
    public var commission: Double?
    /// Milliseconds to delay processing, so an upsell can outrank the first order.
    public var delay: Double?

    public init(
        id: String,
        number: String? = nil,
        total: String? = nil,
        subtotal: Double? = nil,
        discount: Double? = nil,
        tax: Double? = nil,
        shipping: Double? = nil,
        currency: String? = nil,
        date: String? = nil,
        customer: OrderCustomer? = nil,
        coupons: [String]? = nil,
        lineItems: [OrderLineItem]? = nil,
        commission: Double? = nil,
        delay: Double? = nil
    ) {
        self.id = id
        self.number = number
        self.total = total
        self.subtotal = subtotal
        self.discount = discount
        self.tax = tax
        self.shipping = shipping
        self.currency = currency
        self.date = date
        self.customer = customer
        self.coupons = coupons
        self.lineItems = lineItems
        self.commission = commission
        self.delay = delay
    }
    /// The wire spellings differ from the Swift names (`lineItems` -> `line_items`), and this
    /// struct is both encoded to the wire and persisted in the queue, so the mapping has to be
    /// explicit or the two would disagree.
    enum CodingKeys: String, CodingKey {
        case id, number, total, subtotal, discount, tax, shipping, currency, date
        case customer, coupons, commission, delay
        case lineItems = "line_items"
    }

}

/// The top-level `customer` on the unified payload. This is the plain, unhashed identity — the
/// older `email_sha256` / `sendRawIdentifiers` contract is gone. The server updates the
/// customer automatically on every `/v1/identify` call.
public struct UnifiedCustomer: Sendable, Equatable {
    public var name: String?
    /// Normalised (trimmed + lowercased) address, sent in the clear.
    public var email: String?
    /// The host app's internal customer id.
    public var id: String?

    public init(name: String? = nil, email: String? = nil, id: String? = nil) {
        self.name = name
        self.email = email
        self.id = id
    }
}

public struct Customer: Sendable, Equatable {
    public var customerId: String?
    /// Full name as a single string. Prefer this over [firstName]/[lastName] when the host app
    /// already holds a display name — it avoids the SDK guessing how to join the parts.
    public var name: String?
    /// Raw address. Normalised and sent in the clear on the unified payload.
    public var email: String?
    /// Raw phone. Normalised before transmission.
    public var phone: String?
    public var firstName: String?
    public var lastName: String?

    public init(
        customerId: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil
    ) {
        self.customerId = customerId
        self.email = email
        self.phone = phone
        self.firstName = firstName
        self.lastName = lastName
    }
}

public struct RevenuePayload: Sendable, Equatable {
    /// Major currency unit — 2499.00 rupees, not 249900 paise.
    public let amount: Double
    /// ISO-4217.
    public let currency: String

    public init(amount: Double, currency: String) {
        self.amount = amount
        self.currency = currency
    }
}

public struct LogEventOptions: Sendable {
    public var occurredAt: Date?
    public var revenue: RevenuePayload?
    public var orderId: String?
    /// Pre-boxed rather than `[String: Any]` so this type is genuinely `Sendable`.
    public var properties: [String: AnyCodableValue]?

    public init(
        occurredAt: Date? = nil,
        revenue: RevenuePayload? = nil,
        orderId: String? = nil,
        properties: [String: AnyCodableValue]? = nil
    ) {
        self.occurredAt = occurredAt
        self.revenue = revenue
        self.orderId = orderId
        self.properties = properties
    }

    /// Convenience initialiser for the common case of a `[String: Any]` property bag.
    /// Boxes each value eagerly so the stored form stays `Sendable`.
    public init(
        occurredAt: Date? = nil,
        revenue: RevenuePayload? = nil,
        orderId: String? = nil,
        anyProperties: [String: Any]
    ) {
        self.occurredAt = occurredAt
        self.revenue = revenue
        self.orderId = orderId
        self.properties = anyProperties.mapValues(AnyCodableValue.box)
    }
}

public struct InstallResult: Sendable, Equatable {
    public let installId: String
    public let isNewInstall: Bool
    public let attribution: Attribution
    public let deepLink: DeepLink?
    public let config: RemoteConfig

    public init(
        installId: String,
        isNewInstall: Bool,
        attribution: Attribution,
        deepLink: DeepLink?,
        config: RemoteConfig
    ) {
        self.installId = installId
        self.isNewInstall = isNewInstall
        self.attribution = attribution
        self.deepLink = deepLink
        self.config = config
    }
}

public struct ReferralCodeResult: Sendable, Equatable {
    public let valid: Bool
    public let affiliate: Affiliate?
    public let discountType: String?
    public let discountValue: Double?
    public let discountApplied: Bool
    /// Present when `valid` is false, for display to the user.
    public let message: String?

    public init(
        valid: Bool,
        affiliate: Affiliate? = nil,
        discountType: String? = nil,
        discountValue: Double? = nil,
        discountApplied: Bool = false,
        message: String? = nil
    ) {
        self.valid = valid
        self.affiliate = affiliate
        self.discountType = discountType
        self.discountValue = discountValue
        self.discountApplied = discountApplied
        self.message = message
    }
}

public struct AppInfo: Sendable, Equatable {
    public var version: String
    public var build: String?
    public var bundleId: String

    public init(version: String, build: String? = nil, bundleId: String) {
        self.version = version
        self.build = build
        self.bundleId = bundleId
    }
}

public struct DeviceInfo: Sendable, Equatable {
    public var osVersion: String
    public var model: String?
    public var locale: String?
    public var timezone: String?
    /// Minutes from UTC. Sent as `fingerprint.timezoneOffset`.
    public var timezoneOffset: Int?
    public var screen: ScreenInfo?
    public var isEmulator: Bool?

    public init(
        osVersion: String,
        model: String? = nil,
        locale: String? = nil,
        timezone: String? = nil,
        timezoneOffset: Int? = nil,
        screen: ScreenInfo? = nil,
        isEmulator: Bool? = nil
    ) {
        self.osVersion = osVersion
        self.model = model
        self.locale = locale
        self.timezone = timezone
        self.timezoneOffset = timezoneOffset
        self.screen = screen
        self.isEmulator = isEmulator
    }

    public struct ScreenInfo: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var scale: Double

        public init(width: Int, height: Int, scale: Double) {
            self.width = width
            self.height = height
            self.scale = scale
        }
    }

    public init(
        osVersion: String,
        model: String? = nil,
        locale: String? = nil,
        timezone: String? = nil,
        screen: ScreenInfo? = nil,
        isEmulator: Bool? = nil
    ) {
        self.osVersion = osVersion
        self.model = model
        self.locale = locale
        self.timezone = timezone
        self.screen = screen
        self.isEmulator = isEmulator
    }
}

// MARK: - Errors

/// Terminal errors carry a protocol `code`, which tells the caller whether retrying is even
/// sensible. See the error-code table in the protocol spec.
public enum GoAffProErrorCode: String, Sendable {
    case invalidPayload = "invalid_payload"
    case invalidAppId = "invalid_app_id"
    case installIdConflict = "install_id_conflict"
    case clickExpired = "click_expired"
    case referralCodeInvalid = "referral_code_invalid"
    case rateLimited = "rate_limited"
    case serverError = "server_error"
    case networkError = "network_error"
    case notConfigured = "not_configured"
}

public struct GoAffProError: Error, Sendable {
    public let code: GoAffProErrorCode
    public let message: String
    /// Whether retrying the same payload could plausibly succeed.
    public let retryable: Bool
    public let retryAfterMs: Int?
    public let underlying: (any Error)?

    public init(
        code: GoAffProErrorCode,
        message: String,
        retryable: Bool = false,
        retryAfterMs: Int? = nil,
        underlying: (any Error)? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.retryAfterMs = retryAfterMs
        self.underlying = underlying
    }
}

extension GoAffProError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Metadata describing which SDK produced a payload, sent in the `X-GAP-SDK` header and the
/// envelope's `sdk` object.
public struct SDKInfo: Sendable {
    public let platform: String
    public let version: String

    public init(platform: String, version: String) {
        self.platform = platform
        self.version = version
    }

    /// One string shared by the header and the envelope, so they cannot disagree.
    public var headerValue: String { "\(platform)/\(version)" }
}
