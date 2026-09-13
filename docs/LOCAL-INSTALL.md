# Installation

Requires Apple Silicon and macOS 26 or later.

1. Move `Switchboard.app` to Applications and open it.
2. Choose English or Korean, then select your Agent and calling apps in Settings.
3. Install the audio devices from setup. This requires administrator authorization
   and briefly restarts Core Audio, so install before a call.
4. Allow microphone and system-audio access when requested.
5. In the calling app, select **Caller → Switchboard** as its speaker and
   **Agent → Caller** as its microphone.
6. In the Agent app, select **Switchboard → Agent** as its microphone. If only
   **Default** is available, leave it selected.
7. Select your listening device in Switchboard.

Microphone access receives audio from the virtual device. System-audio access
receives playback from your selected Agent app.

## Sessions

Enter a name and press **Start**. Recording begins immediately. You can turn
recording and transcription on or off independently. Choose the two source
languages and your translation language before starting transcription.

**Pause** suspends the session. **Resume** restores its recording and transcription
choices. Paused time remains silent in the audio.

Use **End Session → Save** to choose the file name and location. Sessions are saved
as `.switchboard` files. The default folder is `Music/Switchboard/Recordings` in
your home folder; change it or add library folders in Settings.

Open **Recordings** to play, seek, rename, or export. Export M4A, WAV, or TXT to use
the content in another app. Older `.mihrecording` files can still be opened.

Unfinished sessions appear on the start screen after reopening the app. Open one
to recover its saved contents.

## Removing the app

Open **Settings → Manage audio devices → Remove Drivers** to remove Switchboard's
audio devices. Quit the app, then move it to Trash. Other drivers and saved
sessions remain in place.
