# Contributing

## Development

Use an Apple Silicon Mac with Swift 6.4, the macOS 27 SDK, and Python 3.

```sh
bash scripts/check.sh
bash scripts/build-app.sh release
```

Commit source changes before creating a release bundle. Use the debug preview
command below while iterating on uncommitted changes. See [Versioning](docs/VERSIONING.md)
for build numbers and source-archive builds.

Format Swift with the repository configuration:

```sh
xcrun swift-format format --configuration .swift-format --in-place --recursive Sources Tests Installer Package.swift
```

For a UI preview without starting the audio bridge:

```sh
bash scripts/build-app.sh debug
```

The default SwiftPM build system is `native`. Set
`SWITCHBOARD_SWIFT_BUILD_SYSTEM=swiftbuild` to use Swift Build instead.

## Pull requests

Describe the problem, the change, and how you tested it. Include a regression
test for bug fixes where practical. See [Testing](docs/TESTING.md) for audio and
device scenarios.

Real-time callbacks must remain allocation-free and lock-free. Device UIDs and
recording formats are persistent interfaces; changes need to account for existing
installations and recordings. See [Architecture](docs/ARCHITECTURE.md).

The BlackHole source is pinned in `Vendor/BlackHole/source-lock.json`. Upstream
updates should include the source hashes and corresponding attribution.
