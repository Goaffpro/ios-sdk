import XCTest
@testable import GoAffPro

/// Encoder conformance tests.
///
/// These assert that the Swift encoders reproduce the *same golden fixtures* the React
/// Native, Kotlin and Dart SDKs are checked against. This is the test that actually
/// prevents the four implementations from drifting apart: a passing build tells you nothing
/// about cross-SDK agreement, but a fixture mismatch is unambiguous.
///
/// Fixtures live at `packages/protocol/fixtures` in the repo root. When running from a
/// checkout they are found relative to `#filePath`; when the fixtures cannot be located the
/// tests are skipped rather than failing, so the package still builds standalone.
final class ConformanceTests: XCTestCase {

    // MARK: Fixture loading

    private func fixturesDirectory() throws -> URL {
        // #filePath is <repo>/sdks/ios/Tests/GoAffProTests/ConformanceTests.swift.
        // Walking up five components lands on <repo>.
        //
        // This is derived from #filePath rather than a hardcoded absolute path or a relative
        // path, because the working directory SwiftPM gives a test process is
        // `.build/<config>` — not the package root — so a relative path silently resolves
        // nowhere and the test skips instead of failing. A skipped conformance test is worse
        // than a failing one: it looks green while checking nothing.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let fixtures = url
            .appendingPathComponent("packages")
            .appendingPathComponent("protocol")
            .appendingPathComponent("fixtures")

        guard FileManager.default.fileExists(atPath: fixtures.path) else {
            throw XCTSkip("Protocol fixtures not found at \(fixtures.path); skipping conformance.")
        }
        return fixtures
    }

    private func loadFixture(_ name: String) throws -> [String: Any] {
        let url = try fixturesDirectory().appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("Fixture \(name) is not a JSON object")
        }
        return json
    }

    /// Compares an encoder's output against a fixture, ignoring the one field that is release
    /// identity rather than wire contract.
    ///
    /// `sdk.version` records which SDK release produced a payload, and the fixtures pin it at the
    /// version they were captured with. Conformance answers "do the four encoders emit the same
    /// bytes for the same input", which does not depend on the release, so the value is asserted
    /// to be the SDK's own constant here and then pinned to the fixture's before the deep
    /// comparison. Baking the release version into the fixtures instead would make every version
    /// bump a re-baseline of the shared protocol corpus, which `docs/PUBLISHING.md` says a release
    /// must not be: a bump is the six version files, nothing else.
    private func assertEquivalent(
        _ actual: Any,
        _ expected: Any,
        path: String = "$",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var actual = actual
        if path == "$",
            var aligned = actual as? [String: Any],
            let fixture = expected as? [String: Any]
        {
            alignSdkVersion(&aligned, fixture, file: file, line: line)
            actual = aligned
        }
        assertDeepEquivalent(actual, expected, path: path, file: file, line: line)
    }

    /// Deep, order-insensitive equality with a readable diff path.
    private func assertDeepEquivalent(
        _ actual: Any,
        _ expected: Any,
        path: String = "$",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case let (a as [String: Any], e as [String: Any]):
            let missing = Set(e.keys).subtracting(a.keys)
            let extra = Set(a.keys).subtracting(e.keys)
            XCTAssertTrue(
                missing.isEmpty,
                "\(path): missing keys \(missing.sorted())",
                file: file, line: line
            )
            XCTAssertTrue(
                extra.isEmpty,
                "\(path): unexpected keys \(extra.sorted())",
                file: file, line: line
            )
            for key in Set(a.keys).intersection(e.keys) {
                assertDeepEquivalent(a[key]!, e[key]!, path: "\(path).\(key)", file: file, line: line)
            }

        case let (a as [Any], e as [Any]):
            XCTAssertEqual(a.count, e.count, "\(path): array length differs", file: file, line: line)
            for (index, pair) in zip(a, e).enumerated() {
                assertDeepEquivalent(pair.0, pair.1, path: "\(path)[\(index)]", file: file, line: line)
            }

        case let (a as NSNumber, e as NSNumber):
            // JSONSerialization erases Int/Double; compare numerically so 2499 == 2499.0.
            XCTAssertEqual(
                a.doubleValue, e.doubleValue, accuracy: 1e-9,
                "\(path): expected \(e), got \(a)", file: file, line: line
            )

        default:
            XCTAssertEqual(
                String(describing: actual), String(describing: expected),
                "\(path) differs", file: file, line: line
            )
        }
    }

    // MARK: Shared inputs

    private let app = AppInfo(version: "2.4.1", build: "312", bundleId: "com.acme.shop")

    private let androidDevice = DeviceInfo(
        osVersion: "15",
        model: "Pixel 8",
        locale: "en-IN",
        timezone: "Asia/Kolkata",
        timezoneOffset: 330,
        screen: DeviceInfo.ScreenInfo(width: 412, height: 915, scale: 2.625),
        isEmulator: false
    )

    private let iosDevice = DeviceInfo(
        osVersion: "18.2",
        model: "iPhone15,3",
        locale: "en-IN",
        timezone: "Asia/Kolkata",
        timezoneOffset: 330,
        screen: DeviceInfo.ScreenInfo(width: 393, height: 852, scale: 3),
        isEmulator: false
    )

    private func envelope(_ data: JSONObject, platform: String, at iso: String) throws -> JSONObject {
        Payloads.envelope(
            // Mirrors production, where the envelope is built with the SDK's own version;
            // `assertEquivalent` then pins it to the fixture's.
            sdk: SDKInfo(platform: platform, version: GoAffPro.version),
            data: data,
            sentAt: try XCTUnwrap(GoAffProTimestampFormatter.date(from: iso))
        )
    }

    /// Pins `sdk.version` to the fixture's value, after checking the encoder stamped its own.
    private func alignSdkVersion(
        _ actual: inout [String: Any],
        _ fixture: [String: Any],
        file: StaticString,
        line: UInt
    ) {
        if var sdk = actual["sdk"] as? [String: Any],
            let fixtureSdk = fixture["sdk"] as? [String: Any]
        {
            XCTAssertEqual(
                sdk["version"] as? String, GoAffPro.version,
                "envelope sdk.version must be GoAffPro.version", file: file, line: line
            )
            sdk["version"] = fixtureSdk["version"]
            actual["sdk"] = sdk
        }

        guard var data = actual["data"] as? [String: Any],
            var dataSdk = data["sdk"] as? [String: Any],
            let fixtureDataSdk = (fixture["data"] as? [String: Any])?["sdk"] as? [String: Any]
        else { return }

        XCTAssertEqual(
            dataSdk["version"] as? String, GoAffPro.version,
            "data.sdk.version must be GoAffPro.version", file: file, line: line
        )
        dataSdk["version"] = fixtureDataSdk["version"]
        data["sdk"] = dataSdk
        actual["data"] = data
    }

    // MARK: Tests

    func testInstallMinimalMatchesFixture() throws {
        let fixture = try loadFixture("install-minimal.json")

        let payload = Payloads.unified(
            event: .install,
            // No order exists for an install, so only the generated UUID travels.
            order: Order(id: "9b1c0f8e-2b6a-4b1e-9c7d-3f5a6b7c8d9e"),
            app: app,
            device: iosDevice,
            timestamp: 1758881728,
            installTimestamp: 1758881728,
            platform: "ios",
            deepLink: "acme://promo/diwali"
        )

        assertEquivalent(
            try envelope(payload, platform: "ios", at: "2026-09-26T10:15:30.123Z").jsonObject(),
            fixture
        )
    }

    func testInstallFullMatchesFixture() throws {
        let fixture = try loadFixture("install-full.json")

        let payload = Payloads.unified(
            event: .install,
            order: Order(id: "2a3b4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d"),
            app: app,
            device: androidDevice,
            timestamp: 1758881645,
            installTimestamp: 1758881642,
            platform: "android",
            installReferrer: "utm_source=instagram&utm_medium=paid_social" +
                "&utm_campaign=diwali-2026&gap_click=9f2b7c41-2a3d-4e5f-8b9c-0d1e2f3a4b5c",
            deepLink: "acme://promo/diwali"
        )

        assertEquivalent(
            try envelope(payload, platform: "android", at: "2026-09-26T10:15:30.123Z").jsonObject(),
            fixture
        )
    }

    func testInstallDeferredMatchesFixture() throws {
        let fixture = try loadFixture("install-deferred.json")

        let payload = Payloads.unified(
            event: .install,
            order: Order(id: "3b4c5d6e-7f8a-4b9c-0d1e-2f3a4b5c6d7e"),
            app: app,
            device: iosDevice,
            timestamp: 1758881728,
            installTimestamp: 1758881728,
            platform: "ios"
        )

        assertEquivalent(
            try envelope(payload, platform: "ios", at: "2026-09-26T10:15:30.123Z").jsonObject(),
            fixture
        )
    }

    func testEventPurchaseMatchesFixture() throws {
        let fixture = try loadFixture("event-purchase.json")

        // A purchase is the one event that carries the full order schema.
        let order = Order(
            id: "ORD-5512",
            number: "#5512",
            total: "2499.00",
            subtotal: 2499,
            discount: 250,
            tax: 0,
            shipping: 0,
            currency: "INR",
            date: "2026-09-26T10:20:00.000Z",
            customer: OrderCustomer(
                firstName: "Priya",
                lastName: "Sharma",
                email: "priya@example.com",
                phone: "+919876543210",
                isNewCustomer: false
            ),
            coupons: ["PRIYA10"],
            lineItems: [
                OrderLineItem(
                    name: "Acme T-Shirt (M)",
                    quantity: 1,
                    price: 2499,
                    sku: "TSHIRT-M",
                    productId: "prod_88213",
                    tax: 0,
                    discount: 250
                )
            ],
            delay: 0
        )

        let payload = Payloads.unified(
            event: .purchase,
            order: order,
            app: app,
            device: androidDevice,
            timestamp: 1758882000,
            installTimestamp: 1758881642,
            platform: "android"
        )

        assertEquivalent(
            try envelope(payload, platform: "android", at: "2026-09-26T10:20:01.000Z").jsonObject(),
            fixture
        )
    }

    /// The `customer` is plain, not hashed — the old `email_sha256` digests are gone. If this
    /// fails, the encoder is producing the superseded shape.
    func testIdentifyMatchesFixture() throws {
        let fixture = try loadFixture("identify-customer.json")

        let payload = Payloads.unified(
            event: .identify,
            order: Order(id: "1f4d2c3b-5a69-4e70-8b1c-2d3e4f5a6b7c"),
            app: app,
            device: iosDevice,
            timestamp: 1758882300,
            installTimestamp: 1758881728,
            platform: "ios",
            customer: UnifiedCustomer(
                name: "Priya Sharma",
                email: "priya@example.com",
                id: "cust_99182"
            )
        )

        assertEquivalent(
            try envelope(payload, platform: "ios", at: "2026-09-26T10:25:00.000Z").jsonObject(),
            fixture
        )
    }

    func testDeepLinkRequestMatchesFixture() throws {
        let fixture = try loadFixture("deep-link-request.json")

        let payload = Payloads.unified(
            event: .deepLink,
            order: Order(id: "8a9b0c1d-2e3f-4a5b-6c7d-8e9f0a1b2c3d"),
            app: app,
            device: iosDevice,
            timestamp: 1758882660,
            installTimestamp: 1758881728,
            platform: "ios",
            deepLink: "acme://promo/diwali"
        )

        assertEquivalent(
            try envelope(payload, platform: "ios", at: "2026-09-26T10:31:00.000Z").jsonObject(),
            fixture
        )
    }

    func testReferralCodeRequestMatchesFixture() throws {
        let fixture = try loadFixture("referral-code-request.json")

        let payload = Payloads.unified(
            event: .referral,
            order: Order(id: "5c6d7e8f-9a0b-1c2d-3e4f-5a6b7c8d9e0f"),
            app: app,
            device: androidDevice,
            timestamp: 1758883212,
            installTimestamp: 1758881642,
            platform: "android",
            referralCode: "PRIYA10"
        )

        assertEquivalent(
            try envelope(payload, platform: "android", at: "2026-09-26T10:40:12.000Z").jsonObject(),
            fixture
        )
    }

    /// `order.id` is the only required key inside `order`, and install-based events must mint
    /// it as a UUID. Asserted directly so a regression that starts sending a real order id, or
    /// omits `order`, fails here with a clear message.
    func testInstallEventsCarryOnlyAUUIDOrderId() {
        let payload = Payloads.unified(
            event: .install,
            order: Order(id: "9b1c0f8e-2b6a-4b1e-9c7d-3f5a6b7c8d9e"),
            app: app,
            device: iosDevice,
            timestamp: 1758881728,
            installTimestamp: 1758881728
        ).jsonObject()

        guard let order = payload["order"] as? [String: Any] else {
            return XCTFail("order missing")
        }
        XCTAssertEqual(Set(order.keys), ["id"])

        let id = order["id"] as? String ?? ""
        XCTAssertNotNil(
            id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                     options: .regularExpression),
            "order.id must be a UUID v4, got \(id)"
        )
    }

    /// Every unified body carries all nine fingerprint keys and the discriminator, whatever the
    /// event. The fixtures only cover the happy path, so this pins the invariant directly.
    func testFingerprintAndDiscriminatorAreAlwaysPresent() {
        let payload = Payloads.unified(
            event: .purchase,
            order: Order(id: "ORD-1"),
            app: app,
            // A device with nothing known: the builder must still emit every key.
            device: DeviceInfo(osVersion: "15"),
            timestamp: 1758882000,
            installTimestamp: 1758881642
        ).jsonObject()

        XCTAssertEqual(payload["event"] as? String, "purchase")
        XCTAssertEqual(payload["protocol_version"] as? String, "1")

        let fingerprint = payload["fingerprint"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(fingerprint.keys), [
            "platform", "os_version", "model", "screen_width", "screen_height",
            "screen_scale", "timezone", "timezoneOffset", "locale",
        ])
    }

    /// Optional keys must be *absent*, never `null` — the two are different claims.
    func testOptionalKeysAreOmittedRatherThanNull() {
        let payload = Payloads.unified(
            event: .install,
            order: Order(id: "9b1c0f8e-2b6a-4b1e-9c7d-3f5a6b7c8d9e"),
            app: app,
            device: iosDevice,
            timestamp: 1758881728,
            installTimestamp: 1758881728
        ).jsonObject()

        for key in [
            "install_referrer", "deep_link", "referral_code", "customer",
        ] {
            XCTAssertNil(payload[key], "\(key) must be absent, not null")
        }
    }

    // MARK: Focused unit tests for behaviour the fixtures cannot express

    func testNormalisePhoneHandlesAllDocumentedForms() {
        XCTAssertEqual(Hashing.normalisePhone("+91 98765 43210"), "919876543210")
        XCTAssertEqual(Hashing.normalisePhone("00919876543210"), "919876543210")
        XCTAssertEqual(Hashing.normalisePhone("98765 43210", defaultCountryCode: "91"), "919876543210")
        // Already-prefixed input must not be double-prefixed.
        XCTAssertEqual(Hashing.normalisePhone("919876543210", defaultCountryCode: "91"), "919876543210")
        // No country code and no default: digits only, no guessing.
        XCTAssertEqual(Hashing.normalisePhone("98765-43210"), "9876543210")
    }

    func testNormaliseEmailTrimsAndLowercases() {
        XCTAssertEqual(Hashing.normaliseEmail("  Priya@Example.COM "), "priya@example.com")
    }

    func testTimestampIsAlwaysMillisecondPrecisionUTC() {
        let date = Date(timeIntervalSince1970: 1_774_600_530.123)
        let text = Hashing.timestamp(date)
        XCTAssertTrue(text.hasSuffix("Z"), "must be UTC with a Z suffix, got \(text)")
        XCTAssertNotNil(
            text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression),
            "must be RFC 3339 with exactly 3 fractional digits, got \(text)"
        )
    }

    func testEmptyOptionalObjectsAreOmittedRatherThanSentAsEmpty() {
        // A `put` with a nil string must not create the key at all.
        var obj = JSONObject()
        obj.put("present", "value")
        obj.put("absent", String?.none)

        let json = obj.jsonObject()
        XCTAssertEqual(json["present"] as? String, "value")
        XCTAssertNil(json["absent"], "nil optionals must be omitted, not serialised as null")
    }

    func testExplicitNullIsPreservedWhenRequired() {
        var obj = JSONObject()
        obj.putNull("install_id")
        XCTAssertTrue(obj.jsonObject()["install_id"] is NSNull)
        XCTAssertEqual(obj.jsonString(), #"{"install_id":null}"#)
    }

    func testQueueIsBoundedAndDropsOldestFirst() {
        let store = MemoryStore()
        let queue = EventQueue(store: store, maxSize: 3)

        for index in 1...5 {
            queue.enqueue(QueuedEvent(
                eventId: "e\(index)",
                name: "view",
                occurredAt: "2026-09-26T10:00:0\(index).000Z",
                order: Order(id: "e\(index)")
            ))
        }

        XCTAssertEqual(queue.size, 3)
        XCTAssertEqual(queue.droppedCount, 2)
        XCTAssertEqual(
            queue.peek(3).map(\.eventId), ["e3", "e4", "e5"],
            "oldest events must be dropped first"
        )
    }

    func testDroppedCountIsResetAfterBeingTaken() {
        let store = MemoryStore()
        let queue = EventQueue(store: store, maxSize: 1)
        queue.enqueue(QueuedEvent(eventId: "a", name: "view", occurredAt: "2026-09-26T10:00:00.000Z", order: Order(id: "a")))
        queue.enqueue(QueuedEvent(eventId: "b", name: "view", occurredAt: "2026-09-26T10:00:01.000Z", order: Order(id: "b")))

        XCTAssertEqual(queue.takeDroppedCount(), 1)
        XCTAssertEqual(
            queue.takeDroppedCount(), 0,
            "the counter is a delta since last report; leaving it latched would report the same loss forever"
        )
    }

    func testQueueSurvivesAFreshInstance() {
        let store = MemoryStore()
        let first = EventQueue(store: store)
        first.enqueue(QueuedEvent(
            eventId: "persisted",
            name: "purchase",
            occurredAt: "2026-09-26T10:00:00.000Z",
            order: Order(id: "ORD-PERSISTED", total: "2499.00", currency: "INR")
        ))

        // A new instance over the same store models an app relaunch.
        let second = EventQueue(store: store)
        XCTAssertEqual(second.peek(10).map(\.eventId), ["persisted"])
    }

    func testQueuePreservesFifoOrder() {
        let store = MemoryStore()
        let queue = EventQueue(store: store)

        for index in 1...5 {
            queue.enqueue(QueuedEvent(
                eventId: "e\(index)",
                name: "view",
                occurredAt: "2026-09-26T10:00:0\(index).000Z",
                order: Order(id: "e\(index)")
            ))
        }

        XCTAssertEqual(queue.peek(10).map(\.eventId), ["e1", "e2", "e3", "e4", "e5"])
    }

    func testRemoveDropsOnlyNamedEvents() {
        let store = MemoryStore()
        let queue = EventQueue(store: store)
        queue.enqueue(QueuedEvent(eventId: "a", name: "view", occurredAt: "2026-09-26T10:00:00.000Z", order: Order(id: "a")))
        queue.enqueue(QueuedEvent(eventId: "b", name: "view", occurredAt: "2026-09-26T10:00:01.000Z", order: Order(id: "b")))

        queue.remove(eventIds: ["a"])

        XCTAssertEqual(queue.peek(10).map(\.eventId), ["b"])
    }

    func testAttemptsCounterIncrements() {
        let store = MemoryStore()
        let queue = EventQueue(store: store)
        queue.enqueue(QueuedEvent(eventId: "x", name: "view", occurredAt: "2026-09-26T10:00:00.000Z", order: Order(id: "x")))

        queue.markAttempted(eventIds: ["x"])

        XCTAssertEqual(queue.peek(1).first?.attempts, 1)
    }

    /// Events outside the retention window must be dropped on load, not on the next prune.
    ///
    /// Without this, a device offline for months would replay ancient events the moment it
    /// reconnects, and the server would attribute them to a lookback window they no longer
    /// fall inside.
    func testEventsOlderThanTheRetentionWindowAreDroppedOnLoad() {
        let store = MemoryStore()
        // A timestamp well beyond the 30-day window, in the protocol's exact format.
        let ancient = GoAffProTimestampFormatter.string(
            from: Date().addingTimeInterval(-90 * 24 * 60 * 60)
        )
        store.set(
            StoreKeys.queue,
            #"{"version":1,"events":[{"event_id":"old","name":"view","occurred_at":"\#(ancient)"}],"dropped_count":0}"#
        )

        let queue = EventQueue(store: store)

        XCTAssertEqual(queue.size, 0, "an event older than the retention window must not be replayed")
    }

    func testCorruptQueueIsDiscardedRatherThanWedgingTheSDK() {
        let store = MemoryStore()
        store.set(StoreKeys.queue, "{ this is not valid json")

        let queue = EventQueue(store: store)
        XCTAssertEqual(queue.size, 0, "a corrupt queue must be dropped, not thrown over")

        // And the queue must still be usable afterwards.
        queue.enqueue(QueuedEvent(eventId: "after", name: "view", occurredAt: "2026-09-26T10:00:00.000Z", order: Order(id: "after")))
        XCTAssertEqual(queue.size, 1)
    }
}
