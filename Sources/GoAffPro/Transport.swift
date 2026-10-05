import Foundation

/// HTTP transport: envelope, headers, error classification and backoff.
///
/// Everything retry-related lives here so the four SDKs cannot disagree about it. The
/// classification table is transcribed from `packages/protocol/spec.md`.

public struct TransportOptions: Sendable {
    public var appId: String
    public var baseUrl: String
    public var sdk: SDKInfo
    public var debug: Bool
    /// Injected for tests so backoff does not actually sleep.
    public var sleep: @Sendable (TimeInterval) async -> Void

    public static let defaultBaseUrl = "https://api.goaffpro.com/attribution"

    public init(
        appId: String,
        baseUrl: String = TransportOptions.defaultBaseUrl,
        sdk: SDKInfo = SDKInfo(platform: "ios", version: GoAffPro.version),
        debug: Bool = false,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.appId = appId
        self.baseUrl = baseUrl
        self.sdk = sdk
        self.debug = debug
        self.sleep = sleep
    }
}

/// Base backoff for `5xx`, doubling, capped.
private let backoffBaseSeconds: TimeInterval = 2
private let backoffCapSeconds: TimeInterval = 300
private let maxAttempts = 8

public struct RequestOptions: Sendable {
    public var path: String
    public var body: JSONObject?
    public var installId: String?
    /// Reused across retries so a duplicate delivery is deduped server-side.
    public var idempotencyKey: String?
    public var method: String
    public var query: [String: String]

    public init(
        path: String,
        body: JSONObject? = nil,
        installId: String? = nil,
        idempotencyKey: String? = nil,
        method: String = "POST",
        query: [String: String] = [:]
    ) {
        self.path = path
        self.body = body
        self.installId = installId
        self.idempotencyKey = idempotencyKey
        self.method = method
        self.query = query
    }
}

/// Maps an HTTP status + protocol code to retry semantics.
public func classify(status: Int, code: String?) -> (code: GoAffProErrorCode, retryable: Bool) {
    if status == 429 { return (.rateLimited, true) }
    if status >= 500 { return (.serverError, true) }

    switch code {
    case "invalid_payload": return (.invalidPayload, false)
    case "invalid_app_id": return (.invalidAppId, false)
    case "install_id_conflict": return (.installIdConflict, false)
    case "click_expired": return (.clickExpired, false)
    case "referral_code_invalid": return (.referralCodeInvalid, false)
    case "rate_limited": return (.rateLimited, true)
    case "server_error": return (.serverError, true)
    default:
        // An unknown 4xx is terminal; retrying a request the server has already rejected on
        // semantics is just a slow way to get rate limited.
        return (.serverError, status >= 500)
    }
}

public final class Transport: @unchecked Sendable {
    private let options: TransportOptions
    private let session: URLSession
    private let debugLog: @Sendable (String) -> Void

    public init(
        options: TransportOptions,
        session: URLSession? = nil,
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.options = options
        self.debugLog = debugLog

        if let session {
            self.session = session
        } else {
            // `waitsForConnectivity` would defeat our own timeout handling: a device offline
            // for 30 minutes would hold a flush open rather than failing fast and leaving the
            // events safely in the queue.
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            // We persist the queue ourselves; letting the OS cache responses would make a
            // retry after a network blip look like a success and drop real events.
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    private var baseUrl: String {
        options.baseUrl.hasSuffix("/") ? String(options.baseUrl.dropLast()) : options.baseUrl
    }

    private func url(for request: RequestOptions) -> URL? {
        guard var components = URLComponents(string: baseUrl + request.path) else { return nil }
        if !request.query.isEmpty {
            components.queryItems = request.query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    private func headers(for request: RequestOptions) -> [String: String] {
        var headers: [String: String] = [
            "X-GAP-Protocol": String(goAffProProtocolVersion),
            "X-GAP-SDK": options.sdk.headerValue,
            "X-GAP-App-Id": options.appId,
        ]
        if let installId = request.installId { headers["X-GAP-Install-Id"] = installId }
        if let key = request.idempotencyKey { headers["Idempotency-Key"] = key }
        if request.method != "GET" { headers["Content-Type"] = "application/json" }
        return headers
    }

    /// Performs one request with automatic retries for *retryable* failures only.
    ///
    /// Returns the parsed `data` field of the response envelope. A `204` resolves to `nil`,
    /// which is what `/v1/session` returns.
    @discardableResult
    public func send(_ request: RequestOptions) async throws -> JSONObject? {
        var lastError: GoAffProError?

        for attempt in 1...maxAttempts {
            do {
                guard let url = url(for: request) else {
                    throw GoAffProError(
                        code: .invalidPayload,
                        message: "Could not build a URL for path \(request.path)",
                        retryable: false
                    )
                }

                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = request.method
                for (key, value) in headers(for: request) {
                    urlRequest.setValue(value, forHTTPHeaderField: key)
                }
                if request.method != "GET", let body = request.body {
                    urlRequest.httpBody = Data(body.jsonString().utf8)
                }

                let (data, response) = try await session.data(for: urlRequest)

                guard let http = response as? HTTPURLResponse else {
                    throw GoAffProError(
                        code: .networkError,
                        message: "Response was not HTTP",
                        retryable: true
                    )
                }

                if http.statusCode == 204 { return nil }

                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

                if (200..<300).contains(http.statusCode) {
                    return (parsed?["data"] as? [String: Any]).map(JSONObject.from)
                }

                let errorCode = parsed?["code"] as? String
                let classified = classify(status: http.statusCode, code: errorCode)

                lastError = GoAffProError(
                    code: classified.code,
                    message: parsed?["message"] as? String
                        ?? "Request failed with HTTP \(http.statusCode)",
                    retryable: classified.retryable,
                    retryAfterMs: parsed?["retry_after_ms"] as? Int
                        ?? retryAfterFromHeader(http)
                )

                guard let error = lastError, error.retryable, attempt < maxAttempts else {
                    throw lastError!
                }

                await options.sleep(backoffSeconds(attempt: attempt, retryAfterMs: error.retryAfterMs))
            } catch let error as GoAffProError {
                if !error.retryable || attempt == maxAttempts { throw error }
                lastError = error
                await options.sleep(backoffSeconds(attempt: attempt, retryAfterMs: error.retryAfterMs))
            } catch {
                // A genuine transport failure (offline, DNS, TLS, cancellation).
                if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                    throw GoAffProError(
                        code: .networkError,
                        message: "Request cancelled",
                        retryable: false,
                        underlying: error
                    )
                }

                lastError = GoAffProError(
                    code: .networkError,
                    message: error.localizedDescription,
                    retryable: true,
                    underlying: error
                )

                if attempt == maxAttempts { throw lastError! }
                await options.sleep(backoffSeconds(attempt: attempt, retryAfterMs: nil))
            }
        }

        throw lastError ?? GoAffProError(code: .networkError, message: "Request failed after maximum attempts")
    }

    /// Exponential backoff with full jitter.
    ///
    /// Full jitter (`random(0, cap)`) rather than `cap ± small` because the realistic failure
    /// mode here is a server-side incident where every client retries in lockstep; partial
    /// jitter still produces synchronised retry waves.
    private func backoffSeconds(attempt: Int, retryAfterMs: Int?) -> TimeInterval {
        if let retryAfterMs, retryAfterMs > 0 {
            let base = Double(retryAfterMs) / 1000
            return base + Double.random(in: 0...(base * 0.2))
        }
        let cap = min(backoffBaseSeconds * pow(2, Double(attempt - 1)), backoffCapSeconds)
        return Double.random(in: 0...cap)
    }

    private func retryAfterFromHeader(_ response: HTTPURLResponse) -> Int? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(header)
        else { return nil }
        return Int(seconds * 1000)
    }
}

extension JSONObject {
    /// Builds an ordered object from an unordered dictionary. Order is irrelevant on the
    /// wire; keys are sorted so debug output and fixture diffs are stable.
    static func from(_ dictionary: [String: Any]) -> JSONObject {
        var object = JSONObject()
        for key in dictionary.keys.sorted() {
            object.put(key, JSONValue.from(dictionary[key]!))
        }
        return object
    }
}

extension JSONValue {
    static func from(_ value: Any) -> JSONValue {
        switch value {
        case let v as String: return .string(v)
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            if v.doubleValue == v.doubleValue.rounded() { return .int(v.intValue) }
            return .double(v.doubleValue)
        case let v as [Any]: return .array(v.map(JSONValue.from))
        case let v as [String: Any]: return .object(JSONObject.from(v))
        case is NSNull: return .null
        default: return .string(String(describing: value))
        }
    }
}
