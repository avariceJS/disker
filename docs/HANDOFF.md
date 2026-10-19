# Handoff

Updated: 2026-10-19. Read `MISSION.md`, `AGENTS.md`, and `docs/ARCHITECTURE.md` before product changes. Resume the existing active Pursuing Goal. Work only in this repository on `main`; communicate with the owner in Russian and keep source/docs in English. Measurements are selected-scope and metadata-only by default. Never follow symlinks, treat inaccessible data as zero, infer change from partial observations, or delete real user files.

## Current product

Disker is a native SwiftUI macOS app with Overview, Applications, Folders, Duplicates, History, RAM, and About. It separates macOS-reported volume capacity from selected-path logical bytes and allocated-byte estimates, shows coverage/freshness, and retains bounded local observations. Complete same-path comparisons drive folder, directory, extension, large-file, candidate, and capacity trends; capacity changes are not attributed to folders. Application footprint review uses explicit selection and evidence-scoped associations. Duplicate verification reads selected candidate contents only after separate in-app consent and produces a dry-run after the user picks a keeper. No deletion action exists.

Developer-artifact review shows measured paths, name/Git-marker evidence, risks and consequences, logical and allocated estimates, coverage, overlaps, and complete-history deltas. It now includes up to three read-only investigation prompts: positive complete same-path growth first, then a complete candidate at least 100 MiB allocated. Formatted sizes, confidence, coverage, overlap, and a link to detail are provided; reclaimable space remains unknown. Partial roots suppress prompts and partial subtrees are excluded. This is not general cleanup discovery or a deletion plan. RAM uses snapshots and cautious sampled signals; leak diagnosis and a background service are not implemented.

## Verified this checkpoint

- Xcode 27.1 (27A9275), Swift 6.4 arm64; active developer directory `/Applications/Xcode.app/Contents/Developer`.
- `scripts/check-core.sh`: **70 checks passed** on 2026-10-19, including recommendation ranking/threshold/cap/overlap/high-risk/partial suppression and human-readable byte formatting. A small synthetic scan of 256 file objects and 300 directories completed in 0.013 s wall / 0.013 s process CPU; this is a fixture result, not a general performance benchmark.
- `scripts/package-app.sh standard` and `scripts/package-app.sh sandboxed` both built the current code. Both bundles passed `codesign --verify --strict --deep`; signatures are ad hoc, not Developer ID or notarized. The standard app was copied to `~/Applications/Disker.app`; installed and build executable hashes matched (`73afc73d…`). The installed app launched through `open` and CUA.
- Native UI inspection confirmed real Overview capacity (494.38 GB reported total), selected-root breakdown, and developer-data review. A synthetic complete scan of `Tests` followed by another complete scan showed **+12 KB** for the same `.recommendation-ui-fixture/.build` path. The review sheet ranked that exact growth, showed human-readable sizes, complete coverage, name-only purpose/risk, unknown reclaimable space, and no cleanup conclusion. `Review details` scrolled to the measured source entry. The synthetic fixture was removed afterward. This validates the live positive-growth path; the UI copy continues to identify the fixture scan as synthetic.
- A short idle snapshot of the installed app used eight one-second `/bin/ps` samples: CPU rounded to 0.0% in all samples and RSS remained 114,848 KiB (~112 MiB). This is a brief idle observation, not an energy test.
- `origin/main` was at `01ba514` before this uncommitted recommendation milestone. Publish the next verified commit immediately. `.build` and nested generated artifacts are ignored.

## Repository and validation

Canonical remote: `https://github.com/avariceJS/disker.git`; `.git` is authoritative and `main` is the sole development branch. Do not rewrite/force-push. The preserved timeline includes intentionally simulated 2023 timestamps through 2023-03-10, then actual 2026 commits; continue with actual timestamps and never backdate. App data and bounded history are under `~/Library/Application Support/Disker`; do not clear them during routine validation.

```sh
cd /Users/root1/Desktop/disker
scripts/check-core.sh
scripts/package-app.sh standard
scripts/package-app.sh sandboxed
mkdir -p "$HOME/Applications"
ditto .build/Disker.app "$HOME/Applications/Disker.app"
open "$HOME/Applications/Disker.app"
```

## Next priorities

1. Validate sandboxed bookmark recovery after app relaunch, stale/missing bookmark states, protected-folder partial coverage, and cancellation without changing privacy settings.
2. Verify five-minute scheduled rescans, same-path growth, opt-in reset after relaunch, and pause behavior on a small synthetic scope.
3. Continue evidence-backed application/project attribution and review-only discovery of caches, duplicates, and leftovers; broaden keyboard, resizing, error-state and accessibility verification. Measure a representative scan and a longer idle/energy interval. Keep cleanup read-only until separately authorized.
4. Cleanup acceptance is partial: verified duplicates provide a keeper-selected dry-run, and app-removal footprints are read-only reviews; general cleanup plans and execution are not implemented. Do not claim acceptance criterion 10 complete.
5. Release signing, notarization, installer, App Store review, continuous RAM pressure baselines, and leak diagnosis remain unimplemented.

Resume the existing goal and repeat the mission loop: implement, validate the real app, inspect UI when available, update this handoff, then commit and push each verified milestone to `origin/main`.
