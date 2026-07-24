// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PrintPlexServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PrintPlexCore", targets: ["PrintPlexCore"]),
        .executable(name: "PrintPlexServerApp", targets: ["PrintPlexServerApp"]),
    ],
    dependencies: [
        // API-compatible CryptoKit replacement that also builds on Linux.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
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
        .executableTarget(
            name: "PrintPlexServerApp",
            dependencies: [
                "PrintPlexCore",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            ]
        ),
        .testTarget(
            name: "PrintPlexCoreTests",
            dependencies: ["PrintPlexCore"]
        ),
        .testTarget(
            name: "PrintPlexServerAppTests",
            dependencies: [
                "PrintPlexServerApp",
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)
