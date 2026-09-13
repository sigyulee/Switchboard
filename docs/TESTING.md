# Testing

## Automated checks

```sh
bash scripts/check.sh
```

This runs source and license validation, localization checks, Swift formatting
lint, Swift regression tests, and C queue and driver property tests. The C tests
run under AddressSanitizer and UndefinedBehaviorSanitizer; Swift concurrency and
the C tests also run separately under ThreadSanitizer. Test audio is generated in
temporary directories. These checks do not install drivers or open audio devices.

The Swift test executable is `BridgeChecks`. Run it separately with:

```sh
bash scripts/swift.sh run --configuration debug BridgeChecks
```

Run sanitizer checks separately with:

```sh
bash scripts/check-queue.sh
bash scripts/check-driver.sh
bash scripts/check-swift-concurrency.sh
bash scripts/check-queue.sh thread
bash scripts/check-driver.sh thread
```

The GitHub Actions workflow runs source, localization, and shell syntax checks on
Linux. The `xcode-27` macOS jobs build the release app and both drivers, run Swift
regression checks, and run ASan/UBSan and TSan in separate jobs. Builds and tests
use the standard Apple Silicon runner; they do not install drivers or upload
binaries. Swift TSan products use a separate `.build/thread-sanitizer` directory.

## Audio and device scenarios

| Scenario | Expected behavior |
| --- | --- |
| Driver installation | Both devices appear with the correct names; existing drivers remain available. |
| Audio permissions | Setup reflects granted or denied access and provides a retry action. |
| Two-way routing | Agent audio reaches the caller; caller audio reaches the Agent. |
| Source separation | Caller-only audio appears only in the caller track, and Agent-only audio only in the Agent track. |
| Recording | Start and stop work with either source active, silent, joining late, or disconnecting. |
| Playback and export | Mixed M4A and separate WAV files play with correct timing; seeking works. |
| Headphone reconnection | Removing and replacing headphones, or disconnecting and reconnecting Bluetooth, preserves routing and recording; monitoring resumes without replaying buffered audio. |
| Speaker fallback | Speakers activate only when fallback is enabled; monitoring returns to the selected device when it reconnects. |
| Menu and window lifecycle | Menus dismiss on outside clicks; the main window reopens; repeated launches do not create duplicate bridges. |
| Pause and quit | Recording finishes, routing stops, and the default input is restored unless another app or the user has changed it. |
| Recording recovery | An interrupted recording can be rebuilt from its saved segments; storage failures leave those segments available. |
| Long sessions | Check memory use, source alignment, missing frames, and audible discontinuities over an extended call. |
