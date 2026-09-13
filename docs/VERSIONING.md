# Versioning

Versions follow `MAJOR.MINOR.PATCH`:

- **PATCH** for backward-compatible bug fixes.
- **MINOR** for backward-compatible features; resets PATCH.
- **MAJOR** for incompatible changes; resets MINOR and PATCH.

`VERSION` supplies the app version at build time. Release tags use the form
`v1.0.0` and identify the corresponding source revision.

For development builds, `SWITCHBOARD_BUILD_VERSION` overrides the app version
without changing `VERSION`.
