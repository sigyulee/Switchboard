# Security

## Audio access

Switchboard processes and stores audio locally. Microphone permission provides
virtual-device input; system-audio permission provides Chrome capture. Chrome
may send audio to the Agent service it connects to.

## Driver installation

The installer runs once with administrator authorization. It uses fixed
destinations, verifies the staged payload's identity and hashes, and records
ownership of the two installed drivers. Removal uses that ownership record.

## Recording files

Manifests and audio formats are validated before use. Source paths must be
relative filenames; symbolic links and overflowing frame ranges are rejected.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting when available. Otherwise, open an
issue requesting a private contact channel. Keep exploit details, recordings, and
credentials out of public reports.
