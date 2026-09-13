# Switchboard

Connecting agents with agents.

[한국어](docs/README.ko.md)

Switchboard connects a voice Agent with a calling app on your Mac. Listen to both
sides, record a session, and follow the conversation with on-device transcription
and translation.

## Features

- Select the Agent and calling applications.
- Start, pause, resume, and save named sessions.
- Control recording and transcription independently.
- Separate caller and Agent waveforms and listening levels.
- Live transcripts with translations beneath the original text.
- Recording playback, search, and timestamp navigation.
- M4A, separate-source WAV, and transcript TXT exports.
- Headphone monitoring with optional built-in speaker fallback.
- English and Korean interfaces.

## Requirements

- Apple Silicon Mac running macOS 26 or later.
- Swift 6.2 or later and macOS SDK 26 or later.
- Python 3.
- A calling app with selectable microphone and speaker devices.

Transcription and translation languages depend on the models available on your
Mac. Download missing models from the language controls in the session.

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
2. Select the Agent and calling apps in Settings.
3. Install the audio devices and allow microphone and system-audio access.
4. Select these devices in the two apps:

| App | Setting | Device |
| --- | --- | --- |
| Agent | Microphone | Switchboard → Agent |
| Calling app | Speaker | Caller → Switchboard |
| Calling app | Microphone | Agent → Caller |

If the Agent app only offers **Default**, leave it selected. Switchboard selects
the Mac's input when you start a session.

Choose your listening device, enter a session name, and press **Start**. Recording
begins with the session. Use the recording and transcription controls to change
what is captured.

**Pause** stops the relay, recording, and transcription together. **Resume**
restores your choices. Paused time remains silent in the saved audio.

Choose **End Session**, then **Save** to name the session file and choose its
location. The library shows the default folder and any folders added in Settings.
You can also open a session file directly.

See [installation](docs/LOCAL-INSTALL.md), [architecture](docs/ARCHITECTURE.md),
[testing](docs/TESTING.md), [versioning](docs/VERSIONING.md), and
[contributing](CONTRIBUTING.md).
