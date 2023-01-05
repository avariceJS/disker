# Disker

Disker is a native macOS storage observability app. It separates macOS-reported volume capacity from metadata estimates for folders explicitly selected by the user. It stores bounded scan history locally and reports incomplete coverage instead of presenting access failures as zero bytes.

## Build and run

Requires a Swift 5.9+ toolchain and a macOS 14 or newer SDK. Xcode is useful for normal IDE workflows; the Swift package also builds with Command Line Tools.

```sh
scripts/check-core.sh
scripts/package-app.sh
mkdir -p "$HOME/Applications"
ditto .build/Disker.app "$HOME/Applications/Disker.app"
open "$HOME/Applications/Disker.app"
```

The bundle is an unsigned development app under `.build/Disker.app`. The user-level `~/Applications/Disker.app` copy is convenient for Finder and LaunchServices, but this is not a signed or notarized release and is not installed system-wide in `/Applications`. To remove the app, move it to Trash in Finder; clear Disker's locally stored observations first from **About → Clear Local History…** if desired. The scripts use SwiftPM's `--disable-sandbox` for build subprocesses because this development environment disallows SwiftPM's nested sandbox. This package has no dependencies or build plugins.

## Current behavior

- Reads total and available capacity reported by macOS for `/`.
- Scans only folders selected in the native open panel.
- Reads filesystem metadata only; does not open file contents.
- Does not follow symbolic links; deduplicates hard links within each selected folder.
- Detects changed/replaced directories where possible and marks their coverage partial; a scan is still not an atomic snapshot.
- Flags a direct `.git` metadata entry as a project marker and separately measures a real `.git` directory even when it falls outside the largest-folder ranking. A `.git` file remains a marker only; Disker does not read its contents or claim project ownership.
- Shows logical file size separately from allocated blocks summed from `st_blocks`.
- Saves the latest 180 scan observations under `~/Library/Application Support/Disker/observations.json`.
- Compares complete folder scans to earlier complete scans for the same path; incomplete scans never produce growth deltas.
- Reports complete-only allocated-estimate deltas for matching descendant paths under the same selected root.
- Provides Finder reveal for selected folder roots.
- Provides a separate, manual RAM sample using Mach VM page counts and process resident sizes.
- Does not include cleanup, duplicate hashing, background monitoring, or application ownership attribution yet.

Folder totals are estimates. APFS clones, snapshots, shared blocks, concurrent changes, inaccessible areas, and system-managed storage prevent recursive file totals from reconciling with physical volume usage.

RAM is sampled on demand. Inactive pages may be reclaimable cache; process resident size differs from physical footprint. Disker does not currently report system memory pressure or diagnose leaks.

## Privacy

No account, network service, or telemetry is used. Folder selection is explicit per scan. The app stores metadata observations locally; the About page's confirmed “Clear Local History…” action removes only Disker's saved observations.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/HANDOFF.md](docs/HANDOFF.md).
