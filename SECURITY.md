# Security

## Audio access

Switchboard processes and stores audio locally. Microphone permission allows
input from the virtual audio devices; system-audio permission allows capture of
the selected Agent application's audio. The Agent's service provider and the app
or harness running it may process audio remotely under their own policies.

## Driver installation

The installer runs with administrator authorization. It uses fixed
destinations, verifies the staged payload's identity and hashes, and records
ownership of the three installed drivers.

When removing the app, first use **Settings → Manage audio devices → Remove
Drivers**, which uses that ownership record. Then quit the app and move it to
Trash. Other drivers and saved sessions remain in place.

## Recording files

Manifests and audio formats are validated before use. Source paths must be
relative filenames; symbolic links and overflowing frame ranges are rejected.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting when available. Otherwise, open an
issue requesting a private contact channel. Please keep exploit details,
recordings, and credentials out of public reports.
