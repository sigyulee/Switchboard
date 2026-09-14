# Versioning

Versions follow `MAJOR.MINOR.PATCH`:

- **PATCH** for backward-compatible bug fixes.
- **MINOR** for backward-compatible features; resets PATCH.
- **MAJOR** for incompatible changes; resets MINOR and PATCH.

`VERSION` supplies the release version at build time. Stable release tags use the form
`v1.0.0` and identify the corresponding source revision. Settings displays the
release version, channel, and build number; stable releases omit the channel,
for example `1.1.0 (45)`.

`scripts/build-app.sh` reserves an increasing build number independently of the
release version. Failed reservations are not reused. Local worktrees share the
counter, build records, and retained app bundles through their common Git
directory. The current checkout's `build/current-build.json` points to its latest
completed build record.

Release builds require a clean committed checkout. Debug builds can use local
changes, which are recorded with a source fingerprint. Build records retain the
source revision, build time, and artifact checksums for reproducibility.

`SWITCHBOARD_BUILD_VERSION` overrides the release version without changing
`VERSION`. `SWITCHBOARD_BUILD_NUMBER` supplies an explicitly allocated positive
build number, which must exceed previous local reservations. Use this when
coordinating builds across separate clones or building from a source archive.

`scripts/release-channel.txt` is `beta` until the build has been verified through an actual
call. Compilation and automated checks alone do not qualify a build as stable.
Beta versions appear as `1.1.0 beta (5)` in the app and release title, with tag
`v1.1.0-beta.5`. The number in parentheses identifies the individual build.
Release packages remove local debug paths before signing and recording their
checksums. Distribution ZIP archives omit extended filesystem metadata. Run
`python3 scripts/build-zip.py` after building to package the recorded app.
