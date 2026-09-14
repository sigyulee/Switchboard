# Switchboard

[한국어](docs/README.ko.md)

Connect a voice agent from your app of choice to the macOS Phone app. Listen to
both sides, adjust their volumes independently, and record the conversation.

Verified with **gpt-live-1** on ChatGPT Desktop or Web. I personally recommend it.

## Features

- Select the Agent and calling applications.
- Start, pause, resume, and save named sessions.
- Control recording and transcription independently.
- Separate caller and Agent waveforms and listening levels.
- Live transcripts with translations beneath the original text.
- Recording playback, search, and timestamp navigation.
- Recording dates and missing-audio interval details.
- Complete session-file export, including audio and conversation text.
- M4A, separate-source WAV, and transcript TXT exports.
- Headphone monitoring with optional built-in speaker fallback.
- English and Korean interfaces with adjustable text size.

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

The information button beside each recording shows its start date, duration, and
any missing-audio intervals. Interval counts and total missing time are shown
separately. Expand a source to inspect positions within the recording.

Use **Command-F** in the conversation to find original text or translations; in the
recording list, it searches recordings. You can change transcript languages during
a session and select **Start** to continue with the new settings.

Choose **Text size** in Settings to adjust text throughout the app. A `.switchboard`
session file is a macOS package containing JSON metadata and its audio and text
files. **Export session file** creates a complete copy of that package. Older
`.mihrecording` files remain readable and export as `.switchboard` session files.

See [installation](docs/LOCAL-INSTALL.md), [architecture](docs/ARCHITECTURE.md),
[testing](docs/TESTING.md), [versioning](docs/VERSIONING.md), and
[contributing](CONTRIBUTING.md).
