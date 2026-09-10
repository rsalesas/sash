// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sash",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Sash", targets: ["Sash"]),
        .library(name: "SashTesting", targets: ["SashTesting"]),
    ],
    targets: [
        // Swift cannot catch Objective-C exceptions, and WKURLSchemeTask raises
        // one when it is used after WebKit has torn it down — a race inherent to
        // the API, not a misuse of it. This is the twelve lines that make the
        // catch possible; see Sources/Sash/Scheme/ObjCExceptions.swift.
        .target(
            name: "SashObjC",
            path: "Sources/SashObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Sash",
            dependencies: ["SashObjC"],
            path: "Sources/Sash",
            resources: [.copy("Resources/sash.js")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SashTesting",
            dependencies: ["Sash"],
            path: "Sources/SashTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SashTests",
            dependencies: ["Sash"],
            path: "Tests/SashTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SashIntegrationTests",
            dependencies: ["Sash", "SashTesting"],
            path: "Tests/SashIntegrationTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
