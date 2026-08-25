// swift-tools-version:6.0
// Minimal SwiftPM manifest - enables cross-compilation via Swift SDKs
// (e.g. `make linux-arm64`). Native builds keep using `make` / swiftc.
// Language mode pinned to 5 to match the swiftc build exactly.
// Same recipe as dnsbench v1 (validated by the arm64 musl build).
import PackageDescription

let package = Package(
    name: "dnsbench",
    targets: [
        .executableTarget(
            name: "dnsbench",
            path: ".",
            sources: ["dnsbench.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
