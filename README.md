# Disker

Disker is a native macOS storage observability app. It separates macOS-reported volume capacity from metadata estimates for folders explicitly selected by the user. It stores bounded scan history locally and reports incomplete coverage instead of presenting access failures as zero bytes.

## Build and run

Requires a Swift 5.9+ toolchain and a macOS 14 or newer SDK. Xcode is useful for normal IDE workflows; the Swift package also builds with Command Line Tools.

```sh
swift build
scripts/check-core.sh
swift run Disker
```

Create a native Finder-launchable bundle with `scripts/package-app.sh`; it is an unsigned development app under `.build/Disker.app`. This is not a signed or notarized release and is not installed into `/Applications`. The scripts use SwiftPM's `--disable-sandbox` for build subprocesses because this development environment disallows SwiftPM's nested sandbox. This package has no dependencies or build plugins.

## Current behavior

- Reads total and available capacity reported by macOS for `/`.
- Scans only folders selected in the native open panel.
- Reads filesystem metadata only; does not open file contents.
- Does not follow symbolic links; deduplicates hard links within each selected folder.
- Shows logical file size separately from allocated blocks summed from `st_blocks`.
- Saves the latest 180 scan observations under `~/Library/Application Support/Disker/observations.json`.
- Compares a complete folder scan to the previous complete scan for the same path.
- Provides Finder reveal for selected folder roots.
- Provides a separate, manual RAM sample using Mach VM page counts and process resident sizes.
- Does not include cleanup, duplicate hashing, background monitoring, or application ownership attribution yet.

Folder totals are estimates. APFS clones, snapshots, shared blocks, concurrent changes, inaccessible areas, and system-managed storage prevent recursive file totals from reconciling with physical volume usage.

RAM is sampled on demand. Inactive pages may be reclaimable cache; process resident size differs from physical footprint. Disker does not currently report system memory pressure or diagnose leaks.

## Privacy

No account, network service, or telemetry is used. Folder selection is explicit per scan. The app stores metadata observations locally; history can be removed by deleting the app's `Application Support/Disker` folder after quitting the app. The owner-provided `MISSION.md` is kept in the local workspace and excluded from Git because it contains machine- and project-specific context.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/HANDOFF.md](docs/HANDOFF.md), and [MISSION.md](MISSION.md).
