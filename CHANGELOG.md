# Changelog

## 1.1.3 - 2026-05-26

First public release of FastDup as a downloadable macOS app.

### Added

- Native macOS app bundle release.
- App icon packaged into the app bundle.
- File paths shown in duplicate scan results.
- Quick Look preview support from the duplicate list.

### Fixed

- Bulk duplicate selection now preserves one file in each duplicate group.
- Delete actions now move selected files to the Trash with a batched confirmation flow.
- Network/NAS volumes are handled more safely when deleting files.
- Scanning remains usable while results continue to update.
- Result list stability improved during large scans and scrolling.

### Notes

- Requires macOS 14.0 or later.
- Distributed as an ad-hoc signed app bundle. Apple notarization is not included yet.
