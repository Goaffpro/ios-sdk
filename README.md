# GoAffPro — iOS SDK

Track which affiliate referred each install and each conversion in your iOS app.

Attribution is decided server-side. This SDK collects the evidence it can observe, sends it, and
tells you which affiliate to credit.

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Wiring](#wiring) — lifecycle, deep links, App Tracking Transparency
- [Configuration](#configuration)
- [API](#api)
- [Data model](#data-model)
- [Common recipes](#common-recipes)
- [Troubleshooting](#troubleshooting)

## Requirements

- iOS 13+ (macOS 11+ for development)
- Swift 5.9+
- No third-party dependencies

## Install

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/goaffpro/ios-sdk.git", from: "1.0.0")
]
```

### CocoaPods

```ruby
pod 'GoAffPro', '~> 1.0.0'
```

### Manual

Drag `Sources/GoAffPro` into your target.

## Quick start

Call `configure` as early as possible, then subscribe to attribution.

```swift
import GoAffPro

@main
struct MyApp: App {
    init() {
        Task {
            do {
                // Sends NOTHING. The install report waits for `installAttribution()` below.
                try await GoAffPro.shared.configure(.init(appId: "YOUR_APP_ID"))
            } catch {
                print("GoAffPro configure failed: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    GoAffPro.shared.onAttribution { result in
                        // Fires immediately with the current value (possibly nil), then on
                        // every change — e.g. after a referral code is redeemed.
                        if let affiliate = result?.attribution.affiliate {
                            print("Referred by \(affiliate.code)")
                        }
                    }

                    // Finalize the install. The launch URL rides along on the install report,
                    // so a deferred deep link arrives with the install response.
                    _ = await GoAffPro.shared.installAttribution()
                }
        }
    }
}
```

### Why the install report is explicit

`configure` never sends an install report. That ordering matters because the payload carries the
fingerprint, the install referrer and any launch URL — all captured at the moment you call
`installAttribution()`. So the app decides when the installation is real: after it has seen the
launch URL, after a consent screen, or not at all.

- **Idempotent.** A second call returns the existing result rather than reporting twice.
- **Retryable.** A failure leaves the install unreported and reuses the same `order.id`.
- **Deep-link aware.** `installAttribution(deepLink:)` resolves the URL as part of the install
  response; no separate `handleDeepLink` call is needed for the launch URL.

## Wiring

### 1. Background flush — required

Wire this so queued events are sent before iOS suspends the app.

```swift
@Environment(\.scenePhase) private var scenePhase
// ...
.onChange(of: scenePhase) { phase in
    Task {
        switch phase {
        case .background: await GoAffPro.shared.onAppBackground()
        case .active:     await GoAffPro.shared.onAppForeground()
        default: break
        }
    }
}
```

### 2. Deep links

Forward every inbound URL. The SDK resolves it and notifies your `onDeepLink` listeners; it does
not navigate.

```swift
.onOpenURL { url in
    Task { await GoAffPro.shared.handleDeepLink(url) }
}

// and, for a cold start via a link:
GoAffPro.shared.onDeepLink { link in
    router.handle(link)   // your own routing
}
```

### 3. Finalize the install

Nothing is sent until you call this. Pass the launch URL if there is one.

```swift
_ = await GoAffPro.shared.installAttribution(deepLink: launchUrl)
```

## Configuration

`GoAffPro.shared.configure(.init(...))` — call once, as early as possible.

`GoAffPro.Configuration`:

| Field            | Type                       | Notes                                                              |
| ---------------- | -------------------------- | ------------------------------------------------------------------ |
| `appId`          | `String`                   | **Required.** From the GoAffPro dashboard.                         |
| `baseUrl`        | `String`                   | Override the API host. Staging / self-hosted proxies only.         |
| `debug`          | `Bool`                     | Logs SDK activity with a `[GoAffPro]` prefix. Do not ship enabled. |
| `store`          | `KeyValueStore?`           | Override persistence.                                              |
| `app` / `device` | `AppInfo?` / `DeviceInfo?` | Override auto-collected metadata. Defaults come from the platform. |
| `referrer`       | `ReferrerInfo?`            | Install referrer evidence, if you have it.                         |
| `idfv`           | `String?`                  | Defaults to `UIDevice.current.identifierForVendor`.                |

An empty `appId` throws `GoAffProError`. Calling `configure` twice is a no-op that debug-logs.
`configure` always returns `nil`; use `installAttribution()` for the install result.

## API

### Attribution

| Method                                        | Returns          | Notes                                                                            |
| --------------------------------------------- | ---------------- | -------------------------------------------------------------------------------- |
| `GoAffPro.shared.currentAttribution`          | `InstallResult?` | Latest result, or `nil` if none resolved yet.                                    |
| `GoAffPro.shared.onAttribution { result in }` | `Subscription`   | Fires immediately with the current value (possibly `nil`), then on every change. |
| `GoAffPro.shared.isConfigured`                | `Bool`           | `true` once `configure` has completed.                                           |

Retain the returned `Subscription`; releasing it unsubscribes. Listeners run on a background
queue, so hop to `@MainActor` before touching UI.

### Events

```swift
GoAffPro.shared.logEvent(
    "purchase",
    revenue: .init(amount: 2499, currency: "INR"),
    orderId: "ORD-5512",
    properties: ["coupon": "DIWALI"]
)
```

Synchronous and non-throwing — safe inside a purchase handler. Events are queued and flushed
automatically on a batch threshold, on a timer, and on background.

Use `logEvent(_:options:)` with a `LogEventOptions` to set `eventId` or `occurredAt`.

Event names the dashboard understands: `purchase`, `add_to_cart`, `begin_checkout`, `signup`,
`subscribe`. Any other name is recorded as a custom event.

### Identity

```swift
try await GoAffPro.shared.identify(
    Customer(customerId: user.id, name: user.displayName, email: user.email),
    defaultCountryCode: "91"
)
```

Prefer `name` over `firstName`/`lastName` when the app already holds a display name — the SDK
sends `name` verbatim and only joins the parts when `name` is absent.

Attach a customer after login. The customer travels in the unified payload's top-level
`customer` object and **the server updates it automatically**, so there is no follow-up call.
`email` is trimmed and lowercased before sending.

`defaultCountryCode` and `sendRawIdentifiers` remain in the signature so existing callers keep
compiling, but neither affects the wire format any more: the customer is sent as a plain object
(`name`, `email`, `id`) rather than a set of hashed identifiers. Treat it as PII — TLS only,
never logged, and it changes your app-store data disclosure.

### Referral codes

```swift
let result = try await GoAffPro.shared.redeemReferralCode("DIWALI20")
if result.valid {
    showDiscount(result.discountValue, affiliate: result.affiliate?.name)
} else {
    showError(result.message)
}
```

For a "Have a referral code?" field. A manual code always outranks referrer- and
fingerprint-derived attribution. A successful redemption updates attribution and notifies
`onAttribution` subscribers.

### Deep links

```swift
await GoAffPro.shared.handleDeepLink(url)
let subscription = GoAffPro.shared.onDeepLink { link in /* link.url, link.params, link.fallbackUrl */ }
```

### Lifecycle

| Method                                    | Call from                                                           |
| ----------------------------------------- | ------------------------------------------------------------------- |
| `await GoAffPro.shared.onAppBackground()` | `scenePhase == .background`                                         |
| `await GoAffPro.shared.onAppForeground()` | `scenePhase == .active`                                             |
| `try await GoAffPro.shared.flush()`       | Force a send. Safe to call concurrently — a second caller joins it. |

### Privacy & session

| Method                                        | Notes                                                                                                           |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `GoAffPro.shared.setTrackingEnabled(enabled)` | Opt out. Clears the queue and install id, and persists the choice across relaunches.                            |
| `await GoAffPro.shared.logout()`              | Flushes, then clears the install id, queue and cached attribution. The next `configure` mints a new install id. |

## Data model

```swift
InstallResult(
    installId: String,
    isNewInstall: Bool,
    attribution: Attribution,
    deepLink: DeepLink?,
    config: RemoteConfig
)

Attribution(
    status: AttributionStatus,   // .attributed | .pending | .organic
    tier: AttributionTier,       // .platformReferrer | .probabilistic | .referralCode | .organic
    confidence: Double?,         // 0...1, only meaningful for .probabilistic
    affiliate: Affiliate?,       // id, name?, code
    campaign: Campaign?,         // id, name?, clickId?
    clickedAt: Date?
)
```

`status == .pending` means the server may still match a click; the SDK re-checks once on the next
foreground and then stops.

`ReferralCodeResult`: `valid`, `affiliate?`, `discountType?`, `discountValue?`, `discountApplied`,
`message?`.

### `DeviceToken`: three states

`Configuration.deviceToken` is `String??`, which distinguishes three cases:

| Value          | Meaning                               |
| -------------- | ------------------------------------- |
| `nil`          | Push is not configured.               |
| `.some(nil)`   | Push is configured, but no token yet. |
| `.some("abc")` | The token.                            |

## Common recipes

### Show the referring affiliate on a welcome screen

```swift
let result = try? await GoAffPro.shared.configure(.init(appId: "YOUR_APP_ID"))
if let affiliate = result?.attribution.affiliate {
    welcomeLabel.text = "Welcome — referred by \(affiliate.name ?? affiliate.code)"
}
```

Because `configure` awaits the install report, this is the simplest path when a splash screen is
acceptable.

### Log a purchase from a StoreKit callback

```swift
GoAffPro.shared.logEvent(
    "purchase",
    revenue: .init(amount: price, currency: "USD"),
    orderId: transaction.id
)
```

`logEvent` is synchronous and never throws, so it is safe inside a purchase handler.

### Attach a customer at login

```swift
try await GoAffPro.shared.identify(
    Customer(customerId: user.id, name: user.displayName, email: user.email),
    defaultCountryCode: "91"
)
```

### Respect an in-app opt-out

```swift
GoAffPro.shared.setTrackingEnabled(userConsentGiven)
```

### Use identifiable attribution without polling

```swift
@State private var subscription: Subscription?

var body: some View {
    ContentView()
        .task {
            subscription = GoAffPro.shared.onAttribution { result in
                Task { @MainActor in self.affiliate = result?.attribution.affiliate }
            }
        }
}
```

## Troubleshooting

- **`GoAffProError` on `configure`** — check `appId` is non-empty.
- **`configure` returns `nil`** — expected: `configure` never sends anything. Call
  `installAttribution()` to report the install.
- **`onAttribution` fires with `nil` immediately** — expected. It emits the current value first,
  and stays `nil` until `installAttribution()` is called.
- **No affiliate attributed** — check `installAttribution()` has run, and that the install has
  referrer evidence. `idfv` is collected automatically.
- **Events are not sending** — set `debug: true` and look for `[GoAffPro]` logs.

## License

MIT
