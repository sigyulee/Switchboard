# Switchboard

Connecting agents with agents.

[한국어](docs/README.ko.md)

Switchboard connects a voice Agent in Chrome with the macOS Phone app. Listen to
both sides, adjust their volume independently, and record the conversation.

## Features

- Two-way audio routing between Chrome and Phone.
- Separate caller and Agent waveforms and listening levels.
- Recording, playback, seeking, search, and rename.
- Mixed M4A and separate-source WAV exports.
- Headphone monitoring with optional built-in speaker fallback.
- English and Korean, selectable on first launch and in Settings.

## Requirements

- Apple Silicon Mac running macOS 27 or later.
- Swift 6.4-compatible toolchain and macOS SDK.
- Python 3.

## Build

```sh
bash scripts/check.sh
bash scripts/build-app.sh release
```

The app is generated at `build/Switchboard.app`. To create a DMG:

```sh
bash scripts/build-dmg.sh
```

## Connect

1. Open Switchboard and choose a language.
2. Install the two audio devices and allow microphone and system-audio access.
3. In Phone, select **Phone → Agent** as the speaker and **Chrome → Phone** as the microphone.
4. In Chrome, leave the Agent's microphone on **Default**.
5. Choose a listening device in Switchboard.

Use **Record** to start recording and **Stop** to finish. Saved recordings
are available in **Recordings** for playback and export.

See [installation](docs/LOCAL-INSTALL.md), [architecture](docs/ARCHITECTURE.md),
[testing](docs/TESTING.md), [versioning](docs/VERSIONING.md), and
[contributing](CONTRIBUTING.md).
