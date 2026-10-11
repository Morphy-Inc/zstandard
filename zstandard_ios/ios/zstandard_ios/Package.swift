// swift-tools-version: 5.9
import Foundation
import PackageDescription

let nativePackageDependency: Package.Dependency = {
    if let localPath = ProcessInfo.processInfo.environment["ZSTANDARD_NATIVE_PACKAGE_PATH"] {
        return .package(name: "zstandard", path: localPath)
    }

    // The repository root package exposes the canonical C implementation
    // from zstandard_native/src/zstd without copying it into this plugin.
    // Flutter consumes this manifest through a symlink in the app's
    // ios/Flutter/ephemeral/Packages/.packages, where relative paths resolve
    // against the symlink. Resolve the real location first so the dependency
    // points at this checkout's root (zstandard_ios/ios/zstandard_ios/../../..).
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .resolvingSymlinksInPath()
        .deletingLastPathComponent() // zstandard_ios/ios/zstandard_ios
        .deletingLastPathComponent() // zstandard_ios/ios
        .deletingLastPathComponent() // zstandard_ios
        .deletingLastPathComponent() // repository root
    return .package(name: "zstandard", path: repositoryRoot.path)
}()

let package = Package(
    name: "zstandard_ios",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(
            name: "zstandard-ios",
            targets: ["zstandard_ios"]
        ),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        nativePackageDependency,
    ],
    targets: [
        .target(
            name: "zstandard_ios",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "zstandard-native", package: "zstandard"),
            ],
            path: "Sources/zstandard_ios"
        ),
    ]
)
