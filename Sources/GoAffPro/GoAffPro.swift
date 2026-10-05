import Foundation

// `identifierForVendor()` below is guarded by `#if canImport(UIKit)`, and on iOS that guard is
// TRUE — so UIKit must actually be imported here, not merely be importable. Relying on another
// file in the module to import it only works by accident of compilation order, and `swift build`
// for a macOS host does not compile the iOS branch at all, which is why the omission survives a
// green `swift test`.
#if canImport(UIKit)
import UIKit
#endif

/// The GoAffPro attribution SDK.
///
/// Lifecycle, in the order an app experiences it:
///
/// ```swift
/// let result = try await GoAffPro.shared.configure(appId: "YOUR_APP_ID")
/// GoAffPro.shared.onAttribution { result in ... }
/// GoAffPro.shared.logEvent("purchase", revenue: .init(amount: 2499, currency: "INR"))
/// ```
///
/// `configure` returns as soon as the install report completes, so a caller that wants the
/// affiliate before rendering can `await` it; a caller that would rather not block can
/// subscribe with `onAttribution` and read `currentAttribution` later.
public final class GoAffPro: @unchecked Sendable {
    public static let version = "1.0.0"

    /// Process-wide singleton, matching the `GoAffPro.shared` idiom used by the other SDKs.
    public static let shared = GoAffPro()

    // MARK: State

    private let lock = NSRecursiveLock()
    private var store: KeyValueStore = CompositeStore()
    private var queue: EventQueue?
    private var transport: Transport?
    private var appId: String?
    private var configured = false
    private var trackingEnabled = true
    private var installReported = false
    private var flushing = false
    private var installId: String?
    private var attribution: InstallResult?
    private var remoteConfig = RemoteConfig.default
    private var pendingAttribution = false
    private var flushTimer: DispatchSourceTimer?
    private var debug = false

    /// The UUID used as `order.id` on the install report. Kept in memory for the process
    /// lifetime so a retry of the same install is idempotent; the server is the durable record.
    private var installOrderId: String?

    /// When the SDK first ran on this installation, for `install_timestamp`. Unix seconds.
    private var installTimestamp: Int = 0

    /// A URL that launched the app before `configure()` completed.
    private var pendingDeepLinkUrl: String?

    private var attributionListeners: [(InstallResult?) -> Void] = []
    private var deepLinkListeners: [(DeepLink) -> Void] = []
    private let listenerQueue = DispatchQueue(label: "com.goaffpro.attribution.listeners")

    private init() {}

    // MARK: Configuration

    /// One-shot configuration inputs.
    public struct Configuration: Sendable {
        public var appId: String
        public var baseUrl: String
        public var debug: Bool
        public var store: (any KeyValueStore)?
        public var app: AppInfo?
        public var device: DeviceInfo?
        public var referrer: ReferrerInfo?
        public var idfv: String?

        public init(
            appId: String,
            baseUrl: String = TransportOptions.defaultBaseUrl,
            debug: Bool = false,
            store: (any KeyValueStore)? = nil,
            app: AppInfo? = nil,
            device: DeviceInfo? = nil,
            referrer: ReferrerInfo? = nil,
            idfv: String? = nil
        ) {
            self.appId = appId
            self.baseUrl = baseUrl
            self.debug = debug
            self.store = store
            self.app = app
            self.device = device
            self.referrer = referrer
            self.idfv = idfv
        }
    }

    /// Initialises the SDK. Call once, as early as possible in app startup.
    ///
    /// Sends nothing on its own: the install report waits for an explicit
    /// ``installAttribution(deepLink:)`` call, so the host app controls when its installation
    /// is reported. This method restores persisted state and refreshes remote config.
    ///
    /// - Returns: always `nil`. Use ``installAttribution(deepLink:)`` for the install result.
    @discardableResult
    public func configure(_ configuration: Configuration) async throws -> InstallResult? {
        lock.lock()
        if configured {
            lock.unlock()
            log("configure() called more than once; ignoring. Configuration is immutable.")
            return attribution
        }
        guard !configuration.appId.isEmpty else {
            lock.unlock()
            throw GoAffProError(
                code: .invalidAppId,
                message: "GoAffPro.configure requires a non-empty appId. Find it in your GoAffPro dashboard."
            )
        }

        self.appId = configuration.appId
        self.debug = configuration.debug
        self.store = configuration.store ?? CompositeStore()
        self.queue = EventQueue(store: store)
        self.transport = Transport(
            options: TransportOptions(
                appId: configuration.appId,
                baseUrl: configuration.baseUrl,
                sdk: SDKInfo(platform: "ios", version: GoAffPro.version),
                debug: configuration.debug
            ),
            debugLog: { [weak self] message in self?.log(message) }
        )
        self.configuration = configuration

        let storedEnabled = store.get(StoreKeys.trackingEnabled)
        self.trackingEnabled = storedEnabled != "false"
        self.installId = store.get(StoreKeys.installId)

        // `install_timestamp` is the first launch of this installation. Persist it so events
        // sent days later still carry the original install time rather than "just now".
        if let stored = store.get(StoreKeys.activated), let seconds = Int(stored), seconds > 0 {
            self.installTimestamp = seconds
        } else {
            let now = Hashing.unixSeconds()
            self.installTimestamp = now
            store.set(StoreKeys.activated, String(now))
        }

        if let cached = store.get(StoreKeys.config),
           let data = cached.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(RemoteConfig.self, from: data) {
            self.remoteConfig = decoded
        }

        self.configured = true
        lock.unlock()

        // The install report is deliberately NOT sent here. The host app decides when the
        // installation is real by calling `installAttribution()`. Config is fetched now because
        // it only tunes batching and is useful before the first event.
        await refreshRemoteConfig()

        return nil
    }

    private var configuration: Configuration?

    /// True once `configure` has completed successfully.
    public var isConfigured: Bool {
        lock.lock(); defer { lock.unlock() }
        return configured
    }

    /// The most recent attribution result, or `nil` if none has been resolved yet.
    public var currentAttribution: InstallResult? {
        lock.lock(); defer { lock.unlock() }
        return attribution
    }

    /// Opt out of tracking entirely.
    ///
    /// Does not flush: disabling tracking means queued payloads must not be sent, so the
    /// queue is cleared instead. Persisted, so a relaunch does not silently re-enable.
    public func setTrackingEnabled(_ enabled: Bool) {
        lock.lock()
        trackingEnabled = enabled
        store.set(StoreKeys.trackingEnabled, enabled ? "true" : "false")
        lock.unlock()

        guard !enabled else { return }

        flushTimer?.cancel()
        flushTimer = nil
        queue?.clear()
        store.remove(StoreKeys.installId)

        lock.lock()
        installId = nil
        attribution = nil
        installReported = false
        lock.unlock()

        emitAttribution(nil)
    }

    /// Clears the install identity so the next `configure` mints a new one. Call on logout.
    public func logout() async {
        if trackingEnabled {
            try? await flush()
        }

        flushTimer?.cancel()
        flushTimer = nil

        lock.lock()
        installId = nil
        attribution = nil
        installReported = false
        pendingAttribution = false
        lock.unlock()

        queue?.clear()
        store.remove(StoreKeys.installId)

        emitAttribution(nil)
    }

    // MARK: Attribution

    /// Subscribes to attribution changes.
    ///
    /// Fires immediately with the current value — possibly `nil` — so the caller does not
    /// have to race the install report.
    /// - Returns: a token that must be retained; cancelling it unsubscribes.
    @discardableResult
    public func onAttribution(_ listener: @escaping (InstallResult?) -> Void) -> Subscription {
        lock.lock()
        attributionListeners.append(listener)
        let current = attribution
        lock.unlock()

        listener(current)
        return Subscription { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.attributionListeners.removeAll { $0 as AnyObject === listener as AnyObject }
            self.lock.unlock()
        }
    }

    /// Subscribes to resolved deep links.
    ///
    /// The SDK does not navigate; the app owns routing and knows its own screens.
    @discardableResult
    public func onDeepLink(_ listener: @escaping (DeepLink) -> Void) -> Subscription {
        lock.lock()
        deepLinkListeners.append(listener)
        lock.unlock()

        return Subscription { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.deepLinkListeners.removeAll { $0 as AnyObject === listener as AnyObject }
            self.lock.unlock()
        }
    }

    /// Reports an explicit referral code typed by the user.
    ///
    /// Per the protocol's precedence rules a manual code always outranks referrer- and
    /// fingerprint-derived attribution, because it is explicit human intent.
    public func redeemReferralCode(
        _ code: String,
        source: String = "manual_entry"
    ) async throws -> ReferralCodeResult {
        let transport = try requireTransport()
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw GoAffProError(code: .referralCodeInvalid, message: "Referral code is empty.")
        }

        // `source` no longer travels on the wire: the unified payload carries only the code,
        // and the server cannot tell a typed code from a deep-linked one.
        _ = source

        let body = unifiedPayload(
            event: .referral,
            order: Order(id: Identifiers.newOrderId()),
            occurredAt: nil,
            referralCode: trimmed
        )

        let data = try await transport.send(
            RequestOptions(
                path: "/v1/referral-code",
                body: Payloads.envelope(sdk: sdkInfo(), data: body),
                installId: currentInstallId(),
                idempotencyKey: Identifiers.uuidV4()
            )
        )

        let affiliate = decodeAffiliate(data)
        let discount = data?.value("discount") as? [String: Any]

        let result = ReferralCodeResult(
            valid: (data?.value("valid") as? Bool) ?? false,
            affiliate: affiliate,
            discountType: discount?["type"] as? String,
            discountValue: discount?["value"] as? Double,
            discountApplied: (discount?["applied"] as? Bool) ?? false,
            message: data?.value("message") as? String
        )

        if result.valid, let affiliate {
            lock.lock()
            if let existing = attribution {
                let updated = Attribution(
                    status: .attributed,
                    tier: .referralCode,
                    confidence: nil,
                    affiliate: affiliate,
                    campaign: existing.attribution.campaign,
                    clickedAt: existing.attribution.clickedAt
                )
                attribution = InstallResult(
                    installId: existing.installId,
                    isNewInstall: existing.isNewInstall,
                    attribution: updated,
                    deepLink: existing.deepLink,
                    config: existing.config
                )
                let snapshot = attribution
                lock.unlock()
                emitAttribution(snapshot)
            } else {
                lock.unlock()
            }
        }

        return result
    }

    // MARK: Events

    /// Logs a conversion event.
    ///
    /// Does not throw for ordinary failures — a purchase handler must not fail because
    /// attribution is offline. `async` only because the queue write is behind a lock and may
    /// touch disk.
    public func logEvent(
        _ name: String,
        revenue: RevenuePayload? = nil,
        orderId: String? = nil,
        properties: [String: Any]? = nil
    ) {
        // Boxed eagerly here so the stored options stay `Sendable`; see `LogEventOptions`.
        logEvent(name, options: LogEventOptions(
            revenue: revenue,
            orderId: orderId,
            properties: properties?.mapValues(AnyCodableValue.box)
        ))
    }

    public func logEvent(_ name: String, options: LogEventOptions) {
        lock.lock()
        guard configured, trackingEnabled, let queue else {
            lock.unlock()
            log("logEvent(\"\(name)\") ignored: SDK not configured or tracking disabled.")
            return
        }
        if remoteConfig.disabledEvents?.contains(name) == true {
            lock.unlock()
            log("logEvent(\"\(name)\") suppressed by remote config.")
            return
        }
        let batchSize = remoteConfig.eventBatchSize
        lock.unlock()

        let event = QueuedEvent(
            eventId: Identifiers.uuidV4(),
            name: name,
            occurredAt: Hashing.timestamp(options.occurredAt ?? Date()),
            // `order.id` is the host app's id when it supplied one, and the event's own UUID
            // otherwise. Either way it is stable across retries of the same logical event, so
            // a network retry dedupes instead of double-counting.
            order: Order(
                id: options.orderId ?? Identifiers.uuidV4(),
                total: options.revenue.map { String(format: "%.2f", $0.amount) },
                currency: options.revenue?.currency
            ),
            attempts: nil
        )

        queue.enqueue(event)

        if queue.size >= batchSize {
            Task { [weak self] in
                do { try await self?.flush() } catch { self?.log("flush after batch threshold failed: \(error)") }
            }
        } else {
            scheduleFlush()
        }
    }

    /// Sends everything currently queued.
    ///
    /// Safe to call concurrently: a second caller returns immediately rather than sending a
    /// duplicate batch.
    public func flush() async throws {
        lock.lock()
        guard configured, trackingEnabled, !flushing, let queue, let transport else {
            lock.unlock()
            return
        }
        guard queue.size > 0 else {
            lock.unlock()
            return
        }
        flushing = true
        let batchSize = remoteConfig.eventBatchSize
        let installId = self.installId
        lock.unlock()

        defer {
            lock.lock()
            flushing = false
            lock.unlock()
        }

        flushTimer?.cancel()
        flushTimer = nil

        // One batch per call. Sending everything in a single request risks a body large
        // enough to be rejected, and re-sending the whole backlog after one failure.
        let batch = queue.peek(batchSize)
        guard !batch.isEmpty else { return }

        let ids = batch.map(\.eventId)
        queue.markAttempted(eventIds: ids)

        // `/v1/event` takes one order per request and only supports `purchase`, so a batch is
        // sent as N requests, one per queued order. Sequential rather than parallel so a
        // large backlog cannot open dozens of sockets at once.
        do {
            for event in batch {
                let body = unifiedPayload(
                    event: .purchase,
                    order: event.order,
                    occurredAt: nil
                )

                try await transport.send(
                    RequestOptions(
                        path: "/v1/event",
                        body: Payloads.envelope(sdk: sdkInfo(), data: body),
                        installId: installId,
                        // Keyed on the order, not a fresh UUID, so a retry dedupes.
                        idempotencyKey: "event:\(event.order.id)"
                    )
                )

                queue.remove(eventIds: [event.eventId])
            }
        } catch let error as GoAffProError {
            if error.retryable {
                log("events retained for retry: \(error.message)")
            } else {
                // Terminal: drop the remainder now. Keeping it would block the queue head
                // forever behind an event the server will never accept.
                log("dropping non-retryable events: \(error.message)")
                queue.remove(eventIds: queue.peek(batchSize).map(\.eventId))
            }
            throw error
        }

        // More may have accumulated while this batch was in flight.
        if queue.size > 0 { scheduleFlush() }
    }

    /// Call from the app's background transition handler.
    ///
    /// Flushes with a short deadline because iOS gives roughly five seconds before
    /// suspension and a network call is not guaranteed to finish. Anything unsent is safe in
    /// the persisted queue.
    public func onAppBackground() async {
        flushTimer?.cancel()
        flushTimer = nil

        lock.lock()
        let shouldFlush = configured && trackingEnabled
        lock.unlock()
        guard shouldFlush else { return }

        // `flush()` has no cancellation hook of its own, so race it against a deadline rather
        // than trying to cancel a URLSession task mid-flight.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                do { try await self?.flush() } catch { self?.log("background flush did not complete: \(error)") }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Call when the app returns to the foreground, so timers resume.
    public func onAppForeground() async {
        lock.lock()
        let shouldRun = configured && trackingEnabled
        let pending = pendingAttribution
        if pending { pendingAttribution = false }
        lock.unlock()

        guard shouldRun else { return }

        if pending {
            // `pending` means the server may still match a click. We ask exactly once more and
            // then stop — polling would burn battery to learn nothing in the organic case.
            _ = try? await resolveDeepLink(url: nil, scheme: nil)
        }

        if let queue, queue.size > 0 { scheduleFlush() }
    }

    // MARK: Identity & links

    /// Attaches a customer to this installation.
    ///
    /// The server updates the customer automatically from the payload's top-level `customer`
    /// object, so there is no follow-up call. The email is sent in the clear (normalised) — the
    /// older `sendRawIdentifiers` / `*_sha256` contract is superseded.
    public func identify(
        _ customer: Customer,
        defaultCountryCode: String? = nil,
        sendRawIdentifiers: Bool = false
    ) async throws {
        let transport = try requireTransport()

        // Retained in the signature so existing callers keep compiling; neither affects the
        // wire format any more.
        _ = (defaultCountryCode, sendRawIdentifiers)

        // `customer.name` wins when supplied: the app already knows its own display name, and
        // joining first/last is a guess that gets it wrong for mononyms and for naming orders
        // where the family name comes first.
        let composed = [customer.firstName, customer.lastName]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let name = customer.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name?.isEmpty == false ? name : nil) ?? (composed.isEmpty ? nil : composed)

        let body = unifiedPayload(
            event: .identify,
            order: Order(id: Identifiers.newOrderId()),
            occurredAt: nil,
            customer: UnifiedCustomer(
                name: resolvedName,
                email: customer.email?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                id: customer.customerId
            )
        )

        let data = try await transport.send(
            RequestOptions(
                path: "/v1/identify",
                body: Payloads.envelope(sdk: sdkInfo(), data: body),
                installId: currentInstallId(),
                idempotencyKey: Identifiers.uuidV4()
            )
        )

        if (data?.value("attribution_updated") as? Bool) == true {
            log("Server re-ran attribution after identify; refreshing.")
        }
    }

    /// Call whenever the OS hands the app a URL (custom scheme or universal link).
    ///
    /// Resolves attribution and notifies `onDeepLink` subscribers. The SDK deliberately does
    /// not navigate.
    public func handleDeepLink(_ url: URL) async {
        guard isConfigured else {
            // Remember it: the install report is what carries `deep_link`, and losing the URL
            // because the OS delivered it a moment before configure() finished would break
            // exactly the deferred-deep-link case this endpoint exists for.
            lock.lock()
            pendingDeepLinkUrl = url.absoluteString
            lock.unlock()
            log("handleDeepLink called before configure(); deferred. \(url)")
            return
        }

        let resolved = try? await resolveDeepLink(url: url.absoluteString, scheme: url.scheme)
        guard let resolved else { return }

        lock.lock()
        let listeners = deepLinkListeners
        lock.unlock()

        for listener in listeners {
            listener(resolved)
        }
    }

    // MARK: Internals

    private func sdkInfo() -> SDKInfo {
        SDKInfo(platform: "ios", version: GoAffPro.version)
    }

    /// The host-app facts the encoder needs, resolved from config or the platform collector.
    private var appInfo: AppInfo {
        lock.lock(); defer { lock.unlock() }
        return configuration?.app ?? AppInfo(version: "0.0.0", bundleId: "")
    }

    /// The device facts the fingerprint is built from, with safe fallbacks.
    private var deviceInfo: DeviceInfo {
        lock.lock(); defer { lock.unlock() }
        return configuration?.device ?? DeviceInfo(osVersion: "0.0")
    }

    /// Builds the shared body for one of the five unified endpoints.
    ///
    /// `install_timestamp` is the first launch, recorded once; `timestamp` is when this
    /// particular event happened.
    private func unifiedPayload(
        event: UnifiedEventName,
        order: Order,
        occurredAt: Date?,
        deepLink: String? = nil,
        referralCode: String? = nil,
        customer: UnifiedCustomer? = nil
    ) -> JSONObject {
        lock.lock()
        let installTimestamp = self.installTimestamp
        let referrer = configuration?.referrer
        lock.unlock()

        return Payloads.unified(
            event: event,
            order: order,
            app: appInfo,
            device: deviceInfo,
            timestamp: Hashing.unixSeconds(occurredAt ?? Date()),
            installTimestamp: installTimestamp,
            platform: "ios",
            // The referrer is the raw Play/AASA string; the SDK does not try to re-parse it,
            // because only the server knows which parameters it actually matches on.
            installReferrer: referrer?.raw,
            deepLink: deepLink,
            referralCode: referralCode,
            customer: customer
        )
    }

    private func currentInstallId() -> String? {
        lock.lock(); defer { lock.unlock() }
        return installId
    }

    private func requireTransport() throws -> Transport {
        lock.lock()
        let transport = self.transport
        let configured = self.configured
        lock.unlock()

        guard configured, let transport else {
            throw GoAffProError(
                code: .notConfigured,
                message: "GoAffPro.configure must be awaited before calling this method."
            )
        }
        return transport
    }

    /// Sends the install report and resolves attribution.
    ///
    /// **Nothing is sent until this is called.** ``configure(_:)`` only sets the SDK up; this is
    /// the explicit gate that decides the installation is real. Everything the install payload
    /// carries — the device/app fingerprint, the referrer and any deep-link evidence — is
    /// gathered here, so call it after the app has seen its launch URL and after any consent
    /// screen.
    ///
    /// Idempotent: a second call returns the existing result without reporting twice. On failure
    /// nothing is marked reported and the same `order.id` is reused, so calling again retries
    /// rather than minting a second install.
    ///
    /// - Parameter deepLink: a URL that launched the app. It travels on the install payload, so
    ///   a deferred deep link needs no separate request.
    /// - Returns: the attribution result, or `nil` when tracking is disabled or the request
    ///   failed. Never throws.
    @discardableResult
    public func installAttribution(deepLink: String? = nil) async -> InstallResult? {
        lock.lock()
        if installReported {
            lock.unlock()
            log("installAttribution() called again; this install was already reported.")
            return attribution
        }
        guard trackingEnabled else {
            lock.unlock()
            log("installAttribution() ignored: tracking is disabled.")
            return nil
        }
        lock.unlock()

        return await reportInstall(deepLink: deepLink)
    }

    @discardableResult
    private func reportInstall(deepLink: String? = nil) async -> InstallResult? {
        lock.lock()
        guard !installReported, let transport, let configuration else {
            lock.unlock()
            return attribution
        }
        installReported = true
        let existingInstallId = installId
        lock.unlock()

        let app = configuration.app ?? DeviceCollector.appInfo()
        let device = configuration.device ?? DeviceCollector.current(app: app)

        // No order exists for an install, so the id is a UUID. Generated once per client and
        // reused by the idempotency key below, so a retry cannot mint a second install.
        let orderId = installOrderId ?? Identifiers.newOrderId()

        let body = Payloads.unified(
            event: .install,
            order: Order(id: orderId),
            app: app,
            device: device,
            timestamp: Hashing.unixSeconds(),
            installTimestamp: installTimestamp,
            platform: "ios",
            installReferrer: configuration.referrer?.raw,
            deepLink: deepLink ?? pendingDeepLinkUrl
        )

        lock.lock()
        installOrderId = orderId
        lock.unlock()

        do {
            let data = try await transport.send(
                RequestOptions(
                    path: "/v1/install",
                    body: Payloads.envelope(sdk: sdkInfo(), data: body),
                    installId: existingInstallId,
                    // Stable across retries of *this* install report, so a network retry
                    // cannot mint two install ids for one device.
                    idempotencyKey: "install:\(configuration.appId):\(orderId)"
                )
            )

            guard let data else { return nil }

            var newInstallId = existingInstallId
            if let returned = data.value("install_id") as? String {
                newInstallId = returned
                store.set(StoreKeys.installId, returned)
            }

            let attributionValue = try decodeAttribution(data.value("attribution"))
            let deepLink = try decodeDeepLink(data.value("deep_link"))

            let result = InstallResult(
                installId: newInstallId ?? "",
                isNewInstall: (data.value("is_new_install") as? Bool) ?? false,
                attribution: attributionValue,
                deepLink: deepLink,
                config: remoteConfig
            )

            lock.lock()
            self.installId = newInstallId
            self.attribution = result
            if attributionValue.status == AttributionStatus.pending {
                self.pendingAttribution = true
            }
            lock.unlock()

            emitAttribution(result)
            return result
        } catch {
            // Install failure must not break app startup. Nothing is marked reported, so the
            // host app can call `installAttribution()` again and reuse the same order id.
            lock.lock()
            installReported = false
            lock.unlock()
            log("install report failed; call installAttribution() again to retry: \(error)")
            return nil
        }
    }

    private func resolveDeepLink(url: String?, scheme: String?) async throws -> DeepLink? {
        let transport = try requireTransport()

        // `scheme` no longer travels on the wire: the unified payload carries only the URL.
        _ = scheme

        let body = unifiedPayload(
            event: .deepLink,
            order: Order(id: Identifiers.newOrderId()),
            occurredAt: nil,
            deepLink: url
        )

        let data = try await transport.send(
            RequestOptions(
                path: "/v1/deep-link",
                body: Payloads.envelope(sdk: sdkInfo(), data: body),
                installId: currentInstallId(),
                idempotencyKey: Identifiers.uuidV4()
            )
        )

        guard (data?.value("matched") as? Bool) == true else { return nil }

        let attributionValue = try decodeAttribution(data?.value("attribution"))
        let deepLink = try decodeDeepLink(data?.value("deep_link"))

        lock.lock()
        if let existing = attribution {
            attribution = InstallResult(
                installId: existing.installId,
                isNewInstall: existing.isNewInstall,
                attribution: attributionValue,
                deepLink: deepLink ?? existing.deepLink,
                config: existing.config
            )
            let snapshot = attribution
            lock.unlock()
            emitAttribution(snapshot)
        } else {
            lock.unlock()
        }

        return deepLink
    }

    private func refreshRemoteConfig() async {
        guard let transport, let configuration else { return }

        do {
            let data = try await transport.send(
                RequestOptions(
                    path: "/v1/config",
                    method: "GET",
                    query: [
                        "app_id": configuration.appId,
                        "platform": "ios",
                        "app_version": configuration.app?.version ?? DeviceCollector.appInfo().version,
                    ]
                )
            )

            guard let data else { return }

            lock.lock()
            if let enabled = data.value("enabled") as? Bool { remoteConfig.enabled = enabled }
            if let value = data.value("event_batch_size") as? Int { remoteConfig.eventBatchSize = value }
            if let value = data.value("event_flush_interval_ms") as? Int { remoteConfig.eventFlushIntervalMs = value }
            if let value = data.value("session_timeout_ms") as? Int { remoteConfig.sessionTimeoutMs = value }
            if let value = data.value("lookback_window_hours") as? Int { remoteConfig.lookbackWindowHours = value }
            if let value = data.value("deep_link_scheme") as? String { remoteConfig.deepLinkScheme = value }
            if let value = data.value("universal_link_hosts") as? [String] { remoteConfig.universalLinkHosts = value }
            if let value = data.value("disabled_events") as? [String] { remoteConfig.disabledEvents = value }
            let snapshot = remoteConfig
            lock.unlock()

            if let encoded = try? JSONEncoder().encode(snapshot) {
                store.set(StoreKeys.config, String(decoding: encoded, as: UTF8.self))
            }
        } catch {
            // A failed config fetch is normal — first launch offline, or a transient 5xx. The
            // compiled-in defaults are deliberately conservative and always usable.
            log("remote config fetch failed; using defaults/cache: \(error)")
        }
    }

    private func scheduleFlush() {
        lock.lock()
        let interval = remoteConfig.eventFlushIntervalMs
        let shouldSchedule = configured && trackingEnabled && flushTimer == nil
        lock.unlock()

        guard shouldSchedule else { return }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.flushTimer?.cancel()
            self.flushTimer = nil
            self.lock.unlock()
            Task {
                do { try await self.flush() } catch { self.log("scheduled flush failed: \(error)") }
            }
        }
        timer.resume()

        lock.lock()
        // A timer may have been created by a racing caller; keep the first and cancel ours.
        if flushTimer == nil {
            flushTimer = timer
        } else {
            timer.cancel()
        }
        lock.unlock()
    }

    private func emitAttribution(_ result: InstallResult?) {
        lock.lock()
        let listeners = attributionListeners
        lock.unlock()

        for listener in listeners {
            // A throwing/crashing listener must not break the SDK or the other listeners.
            // Swift closures cannot throw here by signature, so the risk is a crash; running
            // them from a queue keeps that from unwinding our own call stack.
            listenerQueue.async { listener(result) }
        }
    }

    private func activatedKey() -> String {
        if let existing = store.get(StoreKeys.activated) { return existing }
        let key = Identifiers.uuidV4()
        store.set(StoreKeys.activated, key)
        return key
    }
    private func identifierForVendor() -> String? {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    private func decodeAffiliate(_ data: JSONObject?) -> Affiliate? {
        guard let raw = data?.value("affiliate") as? [String: Any],
              let id = raw["id"] as? String,
              let code = raw["code"] as? String
        else { return nil }
        return Affiliate(id: id, name: raw["name"] as? String, code: code)
    }

    private func decodeAttribution(_ value: Any?) throws -> Attribution {
        guard let raw = value as? [String: Any] else {
            return Attribution(
                status: .organic, tier: .organic, confidence: nil,
                affiliate: nil, campaign: nil, clickedAt: nil
            )
        }

        let affiliate = (raw["affiliate"] as? [String: Any]).flatMap { dict -> Affiliate? in
            guard let id = dict["id"] as? String, let code = dict["code"] as? String else { return nil }
            return Affiliate(id: id, name: dict["name"] as? String, code: code)
        }

        let campaign = (raw["campaign"] as? [String: Any]).flatMap { dict -> Campaign? in
            guard let id = dict["id"] as? String else { return nil }
            return Campaign(id: id, name: dict["name"] as? String, clickId: dict["click_id"] as? String)
        }

        return Attribution(
            status: AttributionStatus(rawValue: raw["status"] as? String ?? "organic") ?? .organic,
            tier: AttributionTier(rawValue: raw["tier"] as? String ?? "organic") ?? .organic,
            confidence: raw["confidence"] as? Double,
            affiliate: affiliate,
            campaign: campaign,
            clickedAt: (raw["clicked_at"] as? String).flatMap(GoAffProTimestampFormatter.date(from:))
        )
    }

    private func decodeDeepLink(_ value: Any?) throws -> DeepLink? {
        guard let raw = value as? [String: Any], let url = raw["url"] as? String, !url.isEmpty else {
            return nil
        }
        return DeepLink(
            url: url,
            params: (raw["params"] as? [String: String]) ?? [:],
            fallbackUrl: raw["fallback_url"] as? String
        )
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[GoAffPro] \(message)")
    }
}

/// A cancellable subscription handle.
public final class Subscription {
    private var onCancel: (() -> Void)?
    private let lock = NSLock()

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        let action = onCancel
        onCancel = nil
        lock.unlock()
        action?()
    }

    deinit { cancel() }
}
