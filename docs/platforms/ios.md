# iOS Platform Guide

The **zstandard_ios** package provides the iOS implementation of the Zstandard Flutter plugin using FFI and the native zstd library.

## Support

| Architecture | Support |
|--------------|---------|
| arm64        | Yes (device) |
| x86_64       | Yes (simulator) |

## Installation

Add the main plugin to your app; the iOS implementation is included via the federated plugin:

```yaml
dependencies:
  zstandard: ^1.3.29
```

No additional setup is required for normal use. The plugin registers the iOS implementation automatically when running on iOS.

## Architecture

- **Native layer**: The facebook/zstd C library lives in `zstandard_native/src/zstd/`. With Swift Package Manager, `ios/zstandard_ios/Package.swift` depends on the repository-level `Package.swift`, which compiles those sources in place and links them statically into the app; Dart resolves the symbols through `DynamicLibrary.process()`. With CocoaPods, the podspec syncs the same sources into the ignored `ios/Classes/zstd/` and builds them into the `zstandard_ios` framework, which Dart opens by name.
- **Dart layer**: The package uses Dart FFI and generated bindings to call `ZSTD_compress`, `ZSTD_decompress`, `ZSTD_compressBound`, and `ZSTD_getFrameContentSize`.
- **Isolates**: The implementation may use a helper isolate for async compression/decompression to avoid blocking the UI thread.

## Usage

Use the main package API; the iOS implementation is used automatically:

```dart
import 'package:zstandard/zstandard.dart';

final zstandard = Zstandard();
final compressed = await zstandard.compress(data, 3);
final decompressed = await zstandard.decompress(compressed!);
```

Or use the extensions:

```dart
final compressed = await data.compress(compressionLevel: 3);
final decompressed = await compressed?.decompress();
```

## Building the Native Library

If you are developing the zstandard_ios package:

1. The canonical zstd source is `zstandard_native/src/zstd/`. The repository-level `Package.swift` exposes it as the `zstandard-native` SwiftPM product; `zstandard_native/src/zstd/include/` only holds bridge headers for SwiftPM.
2. `ios/zstandard_ios/Package.swift` is the SwiftPM entry point Flutter uses. It resolves the repository root from its real (symlink-resolved) location; set `ZSTANDARD_NATIVE_PACKAGE_PATH` to point it at another checkout.
3. Release builds dead-strip unreferenced code from the app executable, so every `ZSTD_*` function Dart looks up must be listed in the `-u` linker flags of the repository-level `Package.swift`.
4. The podspec keeps CocoaPods support by syncing the sources into `ios/Classes/zstd/` at install/build time.
5. FFI bindings are generated (e.g. with `ffigen`) from the zstd headers.

See the package’s `ios/` directory and the repo’s [Building](development/building.md) guide.

## Testing

- **Unit tests**: From the package directory: `flutter test`
- **Integration tests**: Run the example app on an iOS device or simulator and run `integration_test` (e.g. `flutter test integration_test/` from the example).

## Performance characteristics

- **Compression/decompression**: Runs on a background isolate so the UI thread stays responsive.
- **Memory**: Peak usage scales with input and output size; high levels (19–22) use more memory.
- **Throughput**: Level 1–3 are fastest; level 22 is slowest. Assembly is disabled in the iOS build for compatibility.

## Known limitations

- Simulator and device use different architectures; ensure the correct slice is built for the target.
- Very large inputs may use significant memory; consider chunking (see [Advanced usage](../guides/advanced-usage.md)).
- Static linking only; no dynamic zstd loading.

## Troubleshooting

- **Library or symbol not found**: Ensure the native target is included in your app’s build and that you are building for the correct architecture (simulator vs device).
- **Crashes**: Verify inputs are valid and not null where required; see [Common Issues](../troubleshooting/common-issues.md).

## See Also

- [Architecture — FFI Implementation](../architecture/ffi-implementation.md)
- [Architecture — Isolate Pattern](../architecture/isolate-pattern.md)
- [API — Main](../api/main-api.md)
