# CodexKit has moved

> [!IMPORTANT]
> CodexKit is now maintained as part of
> [CodexReviewKit](https://github.com/lynnswap/CodexReviewKit). This repository
> is archived and no longer receives changes.

The following Swift products moved without changing their product or module
names:

- `CodexAppServerKit`
- `CodexAppServerKitTesting`
- `CodexDataKit`

## Migrate to CodexReviewKit

Replace the package dependency:

```swift
dependencies: [
    .package(
        url: "https://github.com/lynnswap/CodexReviewKit.git",
        branch: "main"
    ),
]
```

Then update the package identity on each product dependency. Existing imports
and product names remain unchanged:

```swift
.product(name: "CodexAppServerKit", package: "CodexReviewKit"),
.product(name: "CodexDataKit", package: "CodexReviewKit"),
.product(name: "CodexAppServerKitTesting", package: "CodexReviewKit"),
```

The maintained package requires macOS 26 or later and Swift 6.3 or later. See
the [CodexReviewKit README](https://github.com/lynnswap/CodexReviewKit#readme)
for current installation, product documentation, and examples. The
[integration design](https://github.com/lynnswap/CodexReviewKit/blob/main/Docs/codexkit-integration.md)
records the compatibility and ownership changes.

## Frozen macOS 15.4 package

Consumers that must remain on macOS 15.4 can pin the final standalone CodexKit
revision:

```swift
.package(
    url: "https://github.com/lynnswap/CodexKit.git",
    revision: "ab025ed970d30c7679913951bdb9fff20a9b77b1"
)
```

That revision is retained for source and build reproducibility only. It is
frozen, unsupported, and will not receive fixes or dependency updates.
