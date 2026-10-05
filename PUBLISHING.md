# iOS — Publishing

Two distribution channels ship from this directory. Neither involves uploading an artifact
to a central registry: **SwiftPM has no package registry**, so a git tag _is_ the release.

| Channel               | How consumers install          | What "publishing" means                 |
| --------------------- | ------------------------------ | --------------------------------------- |
| SwiftPM (primary)     | `.package(url:from:)` in Xcode | Push a git tag                          |
| CocoaPods (secondary) | `pod 'GoAffPro'` in a Podfile  | Push the podspec to the CocoaPods trunk |

## SwiftPM — the tag is the release

There is no `swift package publish`. SwiftPM resolves a dependency by resolving semver tags
from the git URL, so the release step is:

```sh
cd <repo root>
./scripts/check-versions.sh          # all four SDKs must agree before tagging
git tag -a ios-v0.1.0 -m "GoAffPro iOS SDK 0.1.0"
git push origin ios-v0.1.0
```

Tag naming: use a **per-SDK prefix** (`ios-v0.1.0`, not bare `v0.1.0`). Four SDKs in one repo
otherwise cannot tag independently, and a bare tag collides the first time two of them need a
patch release at the same version number.

Consumers then write:

```swift
.package(url: "https://github.com/goaffpro/ios-sdk.git", from: "0.1.0")
```

**This tag must live in a repository whose root holds `Package.swift`.** SwiftPM resolves
`Package.swift` at the repository root and has no subdirectory option for a *remote*
dependency — `.package(path:)` is for a local checkout only. A tag in this monorepo is therefore
unconsumable via SwiftPM, which is why `sdks/ios` is mirrored to its own repository and tagged
there. See [`docs/PUBLISHING.md`](../../docs/PUBLISHING.md).

That repository must be **public**: SwiftPM resolves anonymously, so a private repo means every
consumer needs an SSH or token URL.

### Why not the Swift Package Registry (SE-0292)?

The protocol exists and SwiftPM supports it, but GitHub's registry is effectively the only
implementation and adoption is negligible. Adding registry auth to a build that already works
with a tag buys nothing.

## CocoaPods — `GoAffPro.podspec`

CocoaPods _does_ have a central index (the "trunk"), so this one is a real publish.

### Validate before you push

```sh
cd sdks/ios
pod lib lint GoAffPro.podspec          # local lint
pod spec lint GoAffPro.podspec         # also resolves the remote source/tag
```

`pod spec lint` will **fail until the matching git tag exists and is pushed**, because the
podspec's `s.source` points at `:tag => s.version`. Order of operations is therefore always:
tag → push tag → `pod spec lint` → `pod trunk push`. A lint failure here is usually just a
missing tag, not a broken podspec.

### Publish

```sh
pod trunk register support@goaffpro.com 'GoAffPro'   # once; confirms via email
pod trunk push GoAffPro.podspec --allow-warnings
```

`pod trunk push` runs `pod spec lint` again server-side. The pod cannot be unpublished once
accepted — only deprecated — so validate locally first.

> **Note:** the podspec has no `LICENSE` file yet. `pod lib lint` fails on a missing
> `:file` license, so `LICENSE` must exist at the **repo root or beside the podspec** before
> CocoaPods publishing works. The `s.license` line already points at `LICENSE`.

## Version bumps

`s.version` in `GoAffPro.podspec` and `GoAffPro.version` in
`Sources/GoAffPro/GoAffPro.swift` are two independent hardcoded copies. The SwiftPM tag is a
third. `./scripts/check-versions.sh` covers the Swift constant; it does **not** yet parse the
podspec — see the release checklist in [`docs/PUBLISHING.md`](../../docs/PUBLISHING.md).

## Checklist

- [ ] `./scripts/check-versions.sh` passes
- [ ] `GoAffPro.podspec` `s.version` matches `version.json`
- [ ] `swift build` and `swift test` pass
- [ ] Tag pushed as `ios-v<version>`
- [ ] `pod spec lint` passes (implies the tag is reachable)
- [ ] `pod trunk push` succeeded
