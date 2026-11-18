// swift-tools-version: 6.0
import PackageDescription
import Foundation

let rustLibrary = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/rust/release").path

let package = Package(
    name: "SquareMail",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClassicKit", targets: ["ClassicKit"]),
        .executable(name: "SquareMail", targets: ["SquareMail"])
    ],
    targets: [
        .target(name: "MessageText", path: "macos/MessageText"),
        .target(name: "ClassicKit", path: "macos/ClassicKit"),
        .systemLibrary(name: "MailBridge", path: "macos/MailBridge"),
        .executableTarget(
            name: "SquareMail",
            dependencies: ["ClassicKit", "MailBridge", "MessageText"],
            path: "macos/SquareMail",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibrary, "-Xlinker", "-dead_strip"]),
                .linkedLibrary("squaremail_core"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .testTarget(name: "MessageTextTests", dependencies: ["MessageText"], path: "macos/MessageTextTests"),
        .testTarget(name: "ClassicKitTests", dependencies: ["ClassicKit"], path: "macos/Tests")
    ],
    swiftLanguageModes: [.v5]
)
