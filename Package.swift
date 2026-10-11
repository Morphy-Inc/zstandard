// swift-tools-version: 5.9
import PackageDescription

// SwiftPM facade for the canonical native implementation kept in
// zstandard_native/src/zstd. The Apple platform packages depend on this
// product instead of carrying another copy of the C sources.
let package = Package(
    name: "zstandard_native",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "zstandard-native",
            targets: ["zstandard_native"]
        ),
    ],
    targets: [
        .target(
            name: "zstandard_native",
            path: "zstandard_native/src/zstd",
            exclude: [
                "deprecated",
                "dictBuilder",
                "dll",
                "legacy",
                "decompress/huf_decompress_amd64.S",
                "module.modulemap",
                // Upstream zstd build files that SwiftPM would otherwise
                // report as unhandled.
                "BUCK",
                "Makefile",
                "README.md",
                "install_oses.mk",
                "libzstd.mk",
                "libzstd.pc.in",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                // Empty, like the sources' own `#define`s, so they don't
                // trigger macro-redefinition warnings.
                .define("ZSTD_STATIC_LINKING_ONLY", to: ""),
                .define("ZSTD_DISABLE_ASM"),
            ],
            // Flutter's SwiftPM integration links this target statically into
            // the application. Keep the FFI entry points in the final image
            // even when release dead-code stripping is enabled. This list must
            // cover every ZSTD_* function that Dart looks up: the one-shot API
            // in the platform packages and the streaming decoder used by
            // zstandard_native's tar.zst extractor.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_compress",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_decompress",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_compressBound",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_getFrameContentSize",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_isError",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_getErrorName",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_createDStream",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_initDStream",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_decompressStream",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_freeDStream",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_DStreamInSize",
                    "-Xlinker", "-u", "-Xlinker", "_ZSTD_DStreamOutSize",
                ])
            ]
        ),
    ]
)
