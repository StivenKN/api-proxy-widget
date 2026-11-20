// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "api-proxy-widget",
    platforms: [.macOS(.v14)],
    targets: [
        // Reads and pools limits from a CLIProxyAPI hub. No UI, so it is testable on its own.
        .target(name: "ProxyLimits"),
        .executableTarget(
            name: "APIProxyWidget",
            dependencies: ["ProxyLimits"]
        ),
        .testTarget(
            name: "ProxyLimitsTests",
            dependencies: ["ProxyLimits"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
