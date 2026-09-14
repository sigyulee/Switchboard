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
Linux. The macOS build job builds the release app and all three drivers and runs Swift
regression checks on Xcode 26.0.1 (`macos-26`) and Xcode 27 (`xcode-27`). Separate
Xcode 27 jobs run ASan/UBSan and TSan. Builds and tests use standard Apple Silicon
runners. Hardware scenarios use an installed driver. Swift TSan products use
a separate `.build/thread-sanitizer` directory.

## Audio and device scenarios

| Scenario | Expected behavior |
| --- | --- |
| Driver installation | All three devices appear with the correct names; existing drivers remain available. |
| Audio permissions | Setup reflects granted or denied access and provides a retry action. |
| Two-way routing | Agent audio reaches the caller; caller audio reaches the Agent. |
| Source separation | Caller-only audio appears only in the caller track, and Agent-only audio only in the Agent track. |
| Session control | Start begins recording; Pause gates both relay directions and capture; Resume preserves the independent recording/transcription choices. |
| Independent capture | Recording-off keeps transcription active without writing PCM; transcription-off keeps recording active. |
| Caller route loss | Stable loss of an observed caller route pauses the session; silence, mute, unknown metadata, and monitor changes do not count as disconnection. |
| Language engines | Installed, missing, unsupported, equal-language, and partially supported pairs produce the corresponding per-source state. |
| Transcript handoff | Slow backfill catches up without duplicate, reordered, or silently lost source audio; recoverable disk audio remains eligible for replay. |
| Playback and export | Mixed M4A and separate WAV files play with correct timing; seeking works. |
| Headphone reconnection | Removing and replacing headphones, or disconnecting and reconnecting Bluetooth, preserves routing and recording; monitoring resumes without replaying buffered audio. |
| Speaker fallback | Speakers activate only when fallback is enabled; monitoring returns to the selected device when it reconnects. |
| Menu and window lifecycle | Menus dismiss on outside clicks; the main window reopens; repeated launches do not create duplicate bridges. |
| Quit | Outstanding session work joins, the unsaved draft remains recoverable, and the owned default-input change is restored. |
| Save and recovery | Cancelling Save leaves a paused session; publication failure preserves the draft; recovered source segments remain readable. |
| Library folders | Default and explicitly added folders are listed; choosing another save destination does not register its folder. |
| Transcript persistence | Final text, translations, language settings, and gaps survive reopen; timestamp navigation and UTF-8 export preserve both speakers. |
| Long sessions | Check memory use, source alignment, missing frames, and audible discontinuities over an extended call. |
