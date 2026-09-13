# Installation

Requires Apple Silicon and macOS 27 or later.

1. Move `Switchboard.app` to Applications and open it.
2. Choose English or Korean.
3. Install the two audio devices from setup. This requires administrator
   authorization and briefly restarts Core Audio, so install before a call.
4. Allow microphone and system-audio access when requested.
5. In Phone, select **Phone → Agent** as the speaker and **Chrome → Phone** as the microphone.
6. In Chrome, keep the Agent's microphone on **Default**.
7. Select your listening device in Switchboard.

Microphone access reads the virtual audio input. System-audio access captures
Chrome playback.

## Recording

Use **Record** to start recording and **Stop** to finish. Open
**Recordings** to play, seek, rename, or export a recording.

Recordings are saved in `Music/Switchboard/Recordings` in your home folder.
Change this location in Settings. Each `.mihrecording` directory contains a
manifest, separate CAF source segments, and a mixed M4A. Export M4A or WAV files
from the library to use them in other apps.

For an interrupted recording, use the library's recovery action to rebuild the
mix from the saved source segments.

## Removing the app

Open **Settings → Manage audio devices → Remove Drivers** to remove Switchboard's
two drivers. Quit the app, then move it to Trash. Existing drivers and recording
files are preserved.
