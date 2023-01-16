# Disker

Disker is a native macOS storage observability app. It separates macOS-reported volume capacity from metadata estimates for folders explicitly selected by the user. It stores bounded capacity, folder, and RAM observations locally and reports incomplete coverage instead of presenting access failures as zero bytes.

## Build and run

Requires a Swift 5.9+ toolchain and a macOS 14 or newer SDK. Xcode is useful for normal IDE workflows; the Swift package also builds with Command Line Tools.

```sh
scripts/check-core.sh
scripts/benchmark-selected-root.sh "$PWD"
scripts/package-app.sh
mkdir -p "$HOME/Applications"
ditto .build/Disker.app "$HOME/Applications/Disker.app"
open "$HOME/Applications/Disker.app"
```

The bundle is an unsigned development app under `.build/Disker.app`; packaging generates its multi-size drive icon from Core Graphics. The user-level `~/Applications/Disker.app` copy is convenient for Finder and LaunchServices, but this is not a signed or notarized release and is not installed system-wide in `/Applications`. To remove the app, move it to Trash in Finder; clear Disker's locally stored observations first from **About → Clear Local History…** if desired. The scripts use SwiftPM's `--disable-sandbox` for build subprocesses because this development environment disallows SwiftPM's nested sandbox. This package has no dependencies or build plugins.

## Development tool inventory

Observed on 2026-10-19. These are shared machine tools; Disker did not install them during this session.

| Tool | Version and location | Role | Update and removal |
| --- | --- | --- | --- |
| Xcode | 27.1 (27A9275), `/Applications/Xcode.app`; active developer directory `/Applications/Xcode.app/Contents/Developer` | Apple SDK, Swift 6.4.0, SwiftPM, build and checks | Update through Apple's Xcode distribution channel. Remove `Xcode.app` in Finder; Command Line Tools are installed separately. |
| Command Line Tools | Apple package 26.6.0, `/Library/Developer/CommandLineTools` package location | Shared system developer tools; not the active `xcode-select` toolchain | Managed by Apple's Command Line Tools installer and package. |
| Git | 2.56.0, `/opt/homebrew/bin/git` | Repository history and publication | Homebrew 7.0.9 manages this shared install: `brew upgrade git` / `brew uninstall git`. The system Git remains separate. |

The Swift package has no third-party dependencies. Node.js is not installed and is not required.

## Current behavior

- Reads total and available capacity reported by macOS for `/`.
- Scans only folders or application bundles selected in the native open panel.
- Provides native **Scan → Choose Folders to Scan…** (`⌘O`) and **Choose an Application Bundle…** (`⌘⇧O`) commands.
- Remembers up to 20 selected scan locations as read-only security-scoped bookmarks in `~/Library/Application Support/Disker/selected-scopes.json`. Users can rescan them manually or remove each saved permission; Disker does not access them on launch or monitor them in the background.
- Provides a separate **Applications** view for explicitly selected `.app` bundles; it measures the bundle only and lets the user manually associate up to 50 separately selected folders. Disker reads the selected bundle's declared `CFBundleIdentifier` and embedded App Groups claim. An exact user app-container path is labeled probable; a matching App Group container is labeled shared. Signature validity, signing identity, and exclusive ownership are not verified; folder sizes are never summed into an app total.
- Compares repeated complete bundle scans and app-associated folder scans of the same selected path using allocated-byte estimates; incomplete results stay explicitly partial.
- Folder-size scans read filesystem metadata only and do not open file contents. The separate, explicit app-selection flow reads the selected bundle's `CFBundleIdentifier` from `Info.plist` and embedded App Groups claim for path hints; it does not validate the signature.
- Does not follow symbolic links; deduplicates hard links within each selected folder.
- Detects changed/replaced directories where possible and marks their coverage partial; a scan is still not an atomic snapshot.
- Flags a direct `.git` metadata entry as a project marker and separately measures a real `.git` directory even when it falls outside the largest-folder ranking. A `.git` file remains a marker only; Disker does not read its contents or claim project ownership.
- Shows logical file size separately from allocated blocks summed from `st_blocks`.
- Adds cautious, exact-name hints for common development storage locations such as SwiftPM build output, Xcode DerivedData, `node_modules`, and Python environments. These hints do not determine ownership or safety to remove.
- Saves up to 180 capacity, folder-scan, and RAM observations under `~/Library/Application Support/Disker/observations.json`. Capacity history is sampled when Disker opens, after a folder scan, or when the user presses Refresh; it is not a background monitor.
- Plots up to 24 comparable root-capacity observations, separating series when reported capacity or the macOS availability method changes. The chart reports system availability and does not explain which folders changed.
- Compares complete folder scans to earlier complete scans for the same path; incomplete scans never produce growth deltas.
- Highlights up to three selected folders with the largest positive allocated-byte changes between complete observations of the same path; a newer partial observation suppresses that path's stale growth signal.
- Plots up to 24 complete allocated-estimate observations for a selected path, including chosen application bundles; partial and future scans are excluded.
- Reports complete-only allocated-estimate deltas for matching descendant paths under the same selected root.
- Provides Finder reveal for selected folder roots.
- Provides a separate, manual RAM sample using Mach VM page counts and process resident sizes.
- Keeps up to 180 on-demand RAM samples locally and plots free and compressed page counts separately from storage. It does not infer pressure or diagnose leaks.
- Flags possible process resident-size growth only across three consecutive manual samples spanning at least 15 minutes, with a stable PID, process name, and kernel-reported start time plus at least 100 MiB growth. It is an investigation signal, not a leak diagnosis.
- Verifies byte-identical duplicate candidates only after a separate folder selection and confirmation. It hashes regular files sharing a logical size, skips symlinks and hard-link aliases, and reports no reclaimable-space estimate.
- Provides an optional dry-run plan from verified duplicate groups only after the user explicitly chooses a path to preserve. The plan identifies exact other paths and unknown risk/reclaimable space; no file action is implemented.
- Does not include full application ownership attribution, automatic associated-data discovery, general cleanup discovery, or background monitoring. The Applications view covers selected app bundles and user-associated folders only.

Folder totals are estimates. APFS clones, snapshots, shared blocks, concurrent changes, inaccessible areas, and system-managed storage prevent recursive file totals from reconciling with physical volume usage.

`scripts/benchmark-selected-root.sh <directory>` measures metadata-scan elapsed time, process CPU time, coverage, and logical/allocated estimates for one explicitly supplied directory. It does not read file contents or persist the observation.

RAM is sampled on demand. Inactive pages may be reclaimable cache; process resident size differs from physical footprint. Disker does not currently report system memory pressure or diagnose leaks. RAM history shares the bounded local observation file and is removed through **About → Clear Local History…**.

Duplicate verification reads file contents only after the user selects folders and confirms the exact scope. SHA-256 results remain in the current app session; no file is moved or removed. Identical content does not establish ownership, safety to delete, or physical space that would be reclaimed.

## Privacy

No account, network service, or telemetry is used. Folder selection is explicit, and later access is limited to the user's manual rescan action. Disker stores metadata observations and app-folder associations locally in `observations.json`; read-only bookmarks for up to 20 selected scan roots are kept separately in `selected-scopes.json`, with owner-only file permissions. The About page's confirmed “Clear Local History…” action removes both files and never changes selected folders or their contents.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/HANDOFF.md](docs/HANDOFF.md).
