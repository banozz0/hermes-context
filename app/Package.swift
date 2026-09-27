// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesContext",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HermesContext", targets: ["HermesContext"]),
    ],
    targets: [
        .target(name: "HermesContextCore"),
        .executableTarget(name: "HermesContext", dependencies: ["HermesContextCore"]),
        .testTarget(name: "HermesContextCoreTests", dependencies: ["HermesContextCore"]),
        // Hosts the real SwiftUI views in a window that is never ordered in, so nothing draws on screen.
        .testTarget(name: "HermesContextAppTests", dependencies: ["HermesContext", "HermesContextCore"]),
    ]
)
