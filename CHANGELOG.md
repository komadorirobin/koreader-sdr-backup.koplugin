# Changelog

## 1.1.6 - 2026-07-28

- Use KOReader's Android external-SD API before trying generic storage discovery.
- Treat `/storage` enumeration as an optional, protected fallback for Android 14 scoped storage.
- Continue scanning `/storage/emulated/0` when listing its parent is denied.

## 1.1.5 - 2026-07-28

- Build the storage manifest cooperatively in KOReader's main process instead of serializing it from a subprocess.
- Yield to the UI every 250 scanned entries and allow the scan to be cancelled normally.
- Guard against a missing manifest before the backup workflow accesses it.

## 1.1.4 - 2026-07-27

- Run OTA file download, verification and installation in KOReader's main process.
- Avoid the Android subprocess hang introduced when the coroutine wrapper was fixed in 1.1.1.
- Keep direct raw-file downloads, per-file SHA-256 checks and strict network timeouts.

## 1.1.3 - 2026-07-27

- Download OTA source files directly from the tagged GitHub tree, avoiding release-asset redirects.
- Remove the Android `unzip` dependency from OTA installation.
- Verify every downloaded plugin file against a committed SHA-256 manifest.
- Enforce KOReader's file-download timeout so an update cannot wait indefinitely.

## 1.1.2 - 2026-07-27

- Fix the connection result handler accidentally shadowing KOReader's gettext function.
- Remove the same identifier-shadowing risk from backup and restore loops.
- Add a regression test that prevents gettext from being shadowed again.

## 1.1.1 - 2026-07-27

- Keep KOReader responsive by running storage scans and network operations in cancellable subprocesses.
- Use a short timeout for connection tests and surface internal errors instead of silently terminating a task.
- Fix OTA checks and installs so they actually run inside KOReader's coroutine wrapper.

## 1.1.0 - 2026-07-27

- Back up every `.sdr` directory while preserving storage roots and exact relative paths.
- Back up KOReader history, statistics, collections and relevant state databases.
- Restore to the same reader or a new device, including replacement memory cards with a new Android UUID.
- Resume interrupted uploads without resending completed files.
- Verify completed backups with SHA-256 on the companion server.
- Add OTA updates from GitHub Releases with mandatory ZIP checksum verification.
- Add repeatable release tooling for future version tags.
