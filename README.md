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
- Shows a low-capacity signal below the larger of 10 GiB or 5% of total capacity. This is a review prompt only; it does not attribute usage or estimate reclaimable space.
- Labels the macOS-reported system volume by name and local/network status when available; capacity history comparisons require a matching volume UUID when both observations contain one.
- Scans only folders or application bundles selected in the native open panel, with at most 50 folder roots per scan.
- Provides native **Scan → Choose Folders to Scan…** (`⌘O`) and **Choose an Application Bundle…** (`⌘⇧O`) commands.
- Remembers up to 20 selected scan locations as read-only security-scoped bookmarks in `~/Library/Application Support/Disker/selected-scopes.json`. Users can rescan them manually or remove each saved permission; Disker does not access them on launch or monitor them in the background.
- Provides a separate **Applications** view for explicitly selected `.app` bundles; it measures the bundle only, displays declared and signed identifiers with local validation status, and lets the user manually associate up to 50 separately selected folders. Disker reads the embedded App Groups claim and locally validates the static code signature. A matching signed identifier receives a stronger path match; a valid signature covering an App Groups claim is labeled more specifically but does not verify developer trust or OS-granted access. Unsigned or invalid signatures retain only a declared-claim label. This does not verify notarization, current use, or exclusive ownership; group data is shared and folder sizes are never summed into an app total.
- Compares repeated complete bundle scans and app-associated folder scans of the same selected path using allocated-byte estimates; incomplete results stay explicitly partial.
- Folder-size scans read filesystem metadata only and do not open file contents. The separate, explicit app-selection flow validates the selected bundle's static signature by reading its signed executable and resources locally; this checks integrity, not notarization or publisher trust, and nothing is uploaded.
- Does not follow symbolic links; deduplicates hard links within each selected folder.
- Excludes sockets, FIFOs, device nodes, and other non-regular entries from file totals and filename categories, while marking the affected root and subtree as partial.
- Revalidates directory and regular-file metadata during scans; detected changes make coverage partial. A scan is still not an atomic snapshot.
- Flags direct `.git` entries as repository markers, separately measures a real root `.git` directory, and retains up to 20 nested repository-marker folders even when they fall outside the 100 largest-folder summaries. Those candidate paths compare growth only within the same selected root and exact relative path; they are not verified project ownership.
- Shows logical file size separately from allocated blocks summed from `st_blocks`.
- Groups selected-folder file metadata by safe filename extension, showing the five largest categories and explicitly noting that names do not verify content or purpose; up to 30 categories are retained.
- Adds cautious, exact-component hints for common SwiftPM, Xcode, npm/pnpm/Yarn, Python, Gradle/Maven/Cargo, CocoaPods/Carthage, simulator, and Docker data locations. They are name matches only; they do not determine ownership, regenerability, or safety to remove.
- Saves up to 180 capacity, folder-scan, and RAM observations under `~/Library/Application Support/Disker/observations.json`. Capacity history is sampled when Disker opens, after a folder scan, or when the user presses Refresh; it is not a background monitor.
- Plots up to 24 comparable root-volume capacity observations, separating series when volume UUID, reported capacity, or the macOS availability method changes. The chart reports system availability and does not explain which folders changed.
- Compares complete folder scans to earlier complete scans for the same path; incomplete scans never produce growth deltas.
- Shows positive filename-category growth only across complete observations of the same selected path; partial scans, legacy summaries, and truncated category sets suppress the comparison.
- Highlights up to three selected folders with the largest positive allocated-byte changes between complete observations of the same path, showing both scan times and Finder reveal; a newer partial observation suppresses that path's stale growth signal.
- Highlights up to three growing subfolders across complete observations of the same selected root and exact relative path. Only paths present in both retained summaries are compared; a newer partial root scan suppresses old signals.
- Keeps the Overview focused on the three largest selected roots and the strongest growth signals, with a direct route to the full Folders breakdown.
- Plots up to 24 complete allocated-estimate observations for a selected path, including chosen application bundles; partial and future scans are excluded.
- Reports complete-only allocated-estimate deltas for matching descendant paths under the same selected root.
- Provides Finder reveal for selected folder roots.
- Provides a separate, manual RAM sample using Mach VM page counts and process resident sizes.
- Offers optional five-minute RAM sampling and records public macOS memory-pressure transitions while Disker is the active app. It is off by default, pauses while inactive, and installs no background service; samples and events stay in bounded local history.
- Keeps up to 180 on-demand RAM samples locally and plots free, compressed, and macOS-reported swap use separately from storage. A zero allocated-swap state is shown distinctly from an unavailable sysctl result. It does not infer pressure or diagnose leaks.
- Flags possible process resident-size growth only across three consecutive samples spanning at least 15 minutes, with a stable PID, process name, and kernel-reported start time plus at least 100 MiB growth. It is an investigation signal, not a leak diagnosis.
- Verifies byte-identical duplicate candidates only after a separate folder selection and confirmation. It hashes regular files sharing a logical size, skips symlinks and hard-link aliases, and reports no reclaimable-space estimate.
- Provides an optional dry-run plan from verified duplicate groups only after the user explicitly chooses a path to preserve. Changed files are removed from groups before planning. The plan identifies exact other paths, retains the verification time, warns that files may have changed since, and reports risk/reclaimable space as unknown; no file action is implemented.
- Does not include full application ownership attribution, automatic associated-data discovery, general cleanup discovery, background storage scans, or system-wide memory-pressure monitoring. The Applications view covers selected app bundles and user-associated folders only.

Folder totals are estimates. APFS clones, snapshots, shared blocks, concurrent changes, inaccessible areas, and system-managed storage prevent recursive file totals from reconciling with physical volume usage.

`scripts/benchmark-selected-root.sh <directory>` measures metadata-scan elapsed time, process CPU time, coverage, and logical/allocated estimates for one explicitly supplied directory. It does not read file contents or persist the observation.

RAM snapshots are manual by default. Optional automatic sampling and system pressure transition observation run only while Disker is active. The transition log does not provide an initial pressure baseline or a continuous current state; gaps and unobserved periods remain unknown. Inactive pages may be reclaimable cache; process resident size differs from physical footprint. Swap measurements are optional and reflect macOS's current allocated swap accounting, not memory pressure. Disker does not diagnose leaks. RAM history shares the bounded local observation file and is removed through **About → Clear Local History…**.

Duplicate verification reads file contents only after the user selects folders and confirms the exact scope. SHA-256 results remain in the current app session; no file is moved or removed. Identical content does not establish ownership, safety to delete, or physical space that would be reclaimed.

## Privacy

No account, network service, or telemetry is used. Folder selection is explicit, and later access is limited to the user's manual rescan action. Disker stores metadata observations and app-folder associations locally in `observations.json` inside a user-only directory, with owner-only file permissions. Read-only bookmarks for up to 20 selected scan roots are kept separately in `selected-scopes.json` with the same permissions. The About page's confirmed “Clear Local History…” action stops RAM monitoring, removes both files, and never changes selected folders or their contents.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/HANDOFF.md](docs/HANDOFF.md).
