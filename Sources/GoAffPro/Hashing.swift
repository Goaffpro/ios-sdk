import Foundation

/// Hashing and encoding helpers.
///
/// Hashing is implemented once here and mirrored exactly in the Kotlin, Dart and TypeScript
/// SDKs. It is a *privacy* control, so a divergence between platforms would be a silent
/// behavioural difference in how users are matched — hence the worked examples in
/// `packages/protocol/spec.md` that every implementation is checked against.

public enum Hashing {
    /// SHA-256, lowercase hex, using CryptoKit.
    public static func sha256Hex(_ input: String) -> String {
        let digest = SHA256Digest.hex(of: Data(input.utf8))
        return digest
    }

    /// Trim + lowercase, per the protocol spec's `email_sha256` definition.
    public static func normaliseEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Normalise a phone number towards E.164 *digits only* (no leading `+`), which is what
    /// the protocol hashes.
    ///
    /// Deliberately conservative: it strips formatting, and only applies a default country
    /// code when the caller supplied one. Guessing a country from a bare local number is how
    /// you silently mismatch real users. iOS has no public API to derive the SIM's country
    /// reliably, so we do not try.
    public static func normalisePhone(_ phone: String, defaultCountryCode: String? = nil) -> String {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitsOnly = trimmed.filter { $0.isNumber }

        if trimmed.hasPrefix("+") { return digitsOnly }

        // International prefix form: 00 44 ... -> 44 ...
        if trimmed.hasPrefix("00") && digitsOnly.hasPrefix("00") {
            return String(digitsOnly.dropFirst(2))
        }

        if let cc = defaultCountryCode {
            let ccDigits = cc.filter { $0.isNumber }
            // Avoid double-prefixing when the caller passes a number that already includes it.
            return digitsOnly.hasPrefix(ccDigits) ? digitsOnly : ccDigits + digitsOnly
        }

        return digitsOnly
    }

    /// RFC 3339 / ISO 8601 UTC with millisecond precision, as the protocol requires.
    public static func timestamp(_ date: Date) -> String {
        GoAffProTimestampFormatter.string(from: date)
    }

    /// Unix epoch **seconds**, which is what the unified payload's `timestamp` and
    /// `install_timestamp` carry — unlike the envelope's RFC 3339 `sent_at`.
    ///
    /// Truncates rather than rounds so two calls a millisecond apart cannot report a second
    /// that has not happened yet.
    public static func unixSeconds(_ date: Date = Date()) -> Int {
        Int(date.timeIntervalSince1970)
    }
}

/// A shared, thread-safe formatter.
///
/// `ISO8601DateFormatter` is not cheap to allocate and `DateFormatter` is not thread-safe,
/// so a single locked instance is used rather than creating one per call. `nonisolated(unsafe)`
/// is avoided by serialising access through a lock.
enum GoAffProTimestampFormatter {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        var text = formatter.string(from: date)
        // ISO8601DateFormatter emits three fractional digits already, but normalise
        // defensively so a future OS change cannot silently alter our wire format.
        if let match = text.range(of: #"\.\d{3,}Z$"#, options: .regularExpression), text.hasSuffix("Z") {
            let fraction = text[match]
            if fraction.count > 4 {
                let keep = fraction.prefix(4) // ".SSS"
                text.replaceSubrange(match, with: keep + "Z")
            }
        }
        return text
    }

    static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }
}

/// UUID v4 from a cryptographically secure generator.
public enum Identifiers {
    /// The `order.id` for an event that has no real order.
    ///
    /// Install-based events (`install`, `deep_link`, `referral`, `identify`) have nothing to
    /// point at, so the protocol asks for a client-generated UUID v4. It still gives the
    /// server a stable row identity and makes a retried report dedupe rather than
    /// double-count, which is why it must be generated once and reused across retries of the
    /// same logical event — callers should persist it, not re-mint it per attempt.
    public static func newOrderId() -> String { uuidV4() }

    public static func uuidV4() -> String {
        UUID().uuidString.lowercased()
    }
}

// MARK: - CryptoKit shim

#if canImport(CryptoKit)
import CryptoKit

enum SHA256Digest {
    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#else
import CommonCrypto

enum SHA256Digest {
    static func hex(of data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif

// MARK: - Device collection

#if canImport(UIKit)
import UIKit
#endif

/// Best-effort collection of the device facts the protocol asks for.
///
/// Every field degrades to `nil` rather than throwing: this runs on the main thread during
/// app launch, and a missing screen size is not worth failing startup over.
enum DeviceCollector {
    static func current(app: AppInfo? = nil) -> DeviceInfo {
        #if canImport(UIKit)
        let screen = UIScreen.main
        let bounds = screen.bounds

        var model: String?
        var isEmulator: Bool?

        // `uname` gives the hardware identifier (e.g. `iPhone15,3`), which is what the
        // protocol asks for — `UIDevice.current.model` only returns "iPhone".
        var systemInfo = utsname()
        if uname(&systemInfo) == 0 {
            let identifier = withUnsafePointer(to: &systemInfo.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            if !identifier.isEmpty { model = identifier }
            isEmulator = identifier.hasPrefix("x86_64") || identifier.hasPrefix("arm64")
                ? ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
                : false
        }

        return DeviceInfo(
            osVersion: UIDevice.current.systemVersion,
            model: model,
            locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            timezone: TimeZone.current.identifier,
            screen: DeviceInfo.ScreenInfo(
                // Report points, not pixels: `nativeScale` multiplies out and the server
                // compares this against other iOS reports.
                width: Int(bounds.width.rounded()),
                height: Int(bounds.height.rounded()),
                scale: Double(screen.scale)
            ),
            isEmulator: isEmulator
        )
        #else
        return DeviceInfo(osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        #endif
    }

    /// The app's own version metadata, read from the bundle.
    static func appInfo(bundle: Bundle = .main) -> AppInfo {
        AppInfo(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundleId: bundle.bundleIdentifier ?? ""
        )
    }

    /// A conventional user agent. Not the WebView UA — this is what the app actually sends,
    /// which is what a server-side match needs.
    static func userAgent(app: AppInfo) -> String {
        "\(app.bundleId)/\(app.version) CFNetwork/\(cfNetworkVersion) Darwin/\(darwinVersion)"
    }

    private static var cfNetworkVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Derived from the OS version rather than read from a private framework; the exact
        // value only matters for fingerprint matching, where near-enough is enough.
        return "\(1400 + os.majorVersion * 20)"
    }

    private static var darwinVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Darwin 23 == iOS 17, 24 == iOS 18, ...
        return "\(os.majorVersion + 6).\(os.minorVersion)"
    }
}
