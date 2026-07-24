// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PrintPlexServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PrintPlexCore", targets: ["PrintPlexCore"]),
    ],
    dependencies: [
        // API-compatible CryptoKit replacement that also builds on Linux.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // zlib exposed as a portable system library (macOS SDK / Linux libz-dev).
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "PrintPlexCore",
            dependencies: [
                "CZlib",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "PrintPlexCoreTests",
            dependencies: ["PrintPlexCore"]
        ),
    ]
)
