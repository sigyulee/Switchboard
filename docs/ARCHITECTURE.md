# Architecture

## Boundaries

| Module | Responsibility | Execution context |
| --- | --- | --- |
| BridgeCore | Session and recording schemas, routing policy, bounded timestamped histories | Value types; no device or UI access |
| AudioRealtime | AUHAL callbacks and bounded stereo queues | C callbacks; one producer and one consumer per queue |
| RecorderKit | PCM conversion, segmented storage, rendering, recovery and waveform extraction | Serial file worker or explicitly owned background task |
| TranscriptKit | On-device speech, translation, bounded input, and transcript journals | Owned actors and bounded asynchronous feeds |
| Switchboard | Device discovery, route lifecycle, permissions and native UI | MainActor for UI; a serial audio-processing queue for endpoints |
| Installer | Fixed-path driver installation and removal | One administrator-authorized command, then exit |

The app captures the selected Agent application’s verified process family. Three virtual drivers separate caller capture, Agent input, and caller input, each with an independent ring buffer. Persistent UIDs identify devices across launches; Core Audio object IDs are resolved at runtime.

## Audio flow

Capture callbacks write stereo Float32 samples and host timestamps to a bounded SPSC queue. They allocate no memory, acquire no locks, perform no file I/O, and do not invoke Swift closures. Endpoint teardown stops the device before its queue is released.

A serial processing queue converts sample rates outside the callbacks, forwards each source to the opposite application, and aligns both sources on a common 48 kHz timeline. Monitoring reads a short delayed window. Output changes reset the monitor cursor; old ring slots are invalid unless their absolute frame tags match.

UI snapshots are copied under a short lock and published when their visible state changes.

## Recording lifecycle

An explicit session Start begins recording. Session control transitions are serialized; recording and transcription retain independent desired states beneath the session gate. Each recording owns one file worker and two segment writers. Admission is bounded in bytes, and accepted blocks are enqueued before finish can pass them. Once finish begins, new blocks are rejected.

A segment is closed after ten seconds, a timestamp discontinuity, or a reader checkpoint. Source files retain their time offsets, so silence and missing sources remain on the same timeline. The mixed M4A uses half gain per source; listening sliders never modify stored samples.

Queue saturation and file errors are persisted as failures. A mix may still be produced from remaining originals, but it stays recoverable rather than becoming a clean completion. A late callback from a previous recorder cannot stop a newer recording.

Manifest values and source formats are validated before arithmetic, allocation, or pointer reads. Sources must be canonical stereo/48 kHz. Recovery does not resample arbitrary imported files into the archive.

Playback preparation, source rendering and waveform work have cancellation ownership. Changing the selected recording invalidates pending work before an older result can start playback.

## Session storage and transcription

A `.switchboard` package contains session metadata, the existing audio manifest
and source segments, and a transcript journal. Session time includes paused
intervals. Audio callbacks use host timestamps; session elapsed time includes
system sleep. Finalization uses one duration for audio and session metadata.

Draft metadata is written atomically. Saving closes and joins the writers, copies
the package to a staging directory beside its destination, and publishes it with
an exclusive rename. A failed copy leaves the source draft intact. Library roots
are the default save folder plus explicitly registered folders.

SpeechAnalyzer consumes bounded, timestamped PCM feeds. Recorded audio can be
replayed from sealed segments before switching to live input. With recording
disabled, only bounded memory is available; unrecoverable input gaps are recorded
in the transcript journal. Neither language engine can block the audio callback.

Partial speech results replace the current utterance. Final results and
translations update the journal under a session-generation token, preventing late
results from modifying another session. Translation runs only on finalized text;
equal source and target languages bypass translation. Language models and pairs
are checked at runtime, and model installation requires a download action.

Older `.mihrecording` packages retain their original decoding and playback path.

## Installation

The command accepts only `install` or `remove`; paths and driver names are fixed in code. It verifies driver identity, architecture, signatures and file hashes. Payloads are copied into a root-only staging directory and checked again there before replacement.

Existing owned drivers are retained as backups until the ownership receipt is written. That receipt is the commit point. Cleanup failures after commit cannot trigger rollback. The helper does not remain running or install a privileged background service.
