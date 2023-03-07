# Handoff

Updated: 2026-10-19. Read `MISSION.md` and `AGENTS.md` before resuming. Source and developer documentation stay in English; report to the owner in Russian. Work only in this repository. `main` is the only branch. Scans are selected-scope and metadata-only by default; never follow symlinks, treat inaccessible items as zero, infer growth from partial observations, or delete user files.

## Product

Disker is a native SwiftUI macOS app installed at `~/Applications/Disker.app`. Its screens are Overview, Applications, Folders, Duplicates, History, RAM, and About. It reports macOS volume capacity separately from selected-path file-tree estimates; folder scans disclose logical bytes, allocated-byte estimates, coverage gaps, symlinks, volume boundaries, and selected-path history. It stores bounded local history (up to 180 observations), compares complete observations for the same path and volume, and shows capacity charts, folder/directory growth, extension summaries, and up to 20 largest files. A file-growth signal requires the same relative path in both complete top-file summaries; omitted rows remain unknown.

Application bundle measurement and read-only app-footprint review rely on explicit selection and evidence-scoped associations. Duplicate verification reads content only after the user chooses roots and confirms a candidate estimate; its review is dry-run and has no deletion action. RAM is a separate subsystem with point samples, optional active-app-only monitoring, system-pressure transitions, and cautious process-growth language. Automatic monitoring is off after relaunch. Disker does not offer file cleanup/deletion.

Overview and selected-folder details now open a read-only developer-artifact review from the latest selected scan. It shows exact paths, observation time, separate logical and allocated estimates, classifications, consequences, evidence, coverage, truncation, and overlapping paths. Unsafe relative paths from stored summaries are rejected. Finder reveal and native re-selection are available; reclaimable bytes remain unknown and there is no deletion action.

## Verified state

- Xcode 27.1 (27A9275), Swift 6.4, arm64; `xcode-select -p` is `/Applications/Xcode.app/Contents/Developer`.
- `scripts/check-core.sh`: **63 checks passed** on 2026-10-19, including scanner boundaries/partial coverage, duplicate consent and mutation safety, bounded history, bookmark mismatch rejection, app attribution, directory/file growth, developer-artifact classification/overlap/partial coverage, unsafe candidate-path rejection, and reset safety.
- `scripts/package-app.sh standard` and `scripts/package-app.sh sandboxed` both built and passed strict ad-hoc signature verification. The ordinary build is installed at `~/Applications/Disker.app`; neither build is Developer ID-signed or notarized.
- Opened the native app and inspected its Overview. With the sandboxed build, selected `/Users/root1/Desktop/disker` through the native folder picker, scanned it, then rescanned using its saved read-only bookmark. History showed both observations. The Folders UI visibly showed largest subfolders, extension categories, and largest files. The scan measured 714.1 MB logical and 735.3 MB allocated estimate, partial because two SwiftPM symlinks were excluded. This selected-folder scan did not read file contents. No additional macOS permission was granted; CUA UI control and inspection worked.
- Opened the sandboxed app and visually/accessibly checked the new development-artifact review. It showed `.build` as a partial Swift build candidate, dSYM and `.git` as high-risk entries, exact paths, separate logical/allocated estimates, and explicit overlap warnings. Its native re-selection action opened `NSOpenPanel` at the chosen path; cancelling did not start a scan. No delete action appears.
- The sandboxed RAM page recorded one point sample (24 GB installed, no swap allocation); process enumeration was denied by the sandbox and the UI disclosed that. The latest core host sample read 24 GiB physical RAM and found process enumeration available (499 processes); this is a point sample, not leak evidence.
- Latest system root-volume sample: 494,384,795,648 total and 443,274,215,488 available bytes under macOS important-usage accounting. Their difference is not attributed file usage.
- Earlier metadata-only benchmark: 6,927 workspace files in 0.324 s wall / 0.323 s CPU, 12.3 MiB max RSS, 731,189,248 allocated-estimate bytes; `du` reported 714,052 KiB. Coverage was partial due to two excluded SwiftPM symlinks. Installed app scan: 4 files, 0.002 s wall, 6,149,042 logical and 6,156,288 estimated allocated bytes; `du` reported 6,012 KiB.
- `CUA` review covered the real overview, selected-folder detail, duplicate/app empty states, RAM, and History. The synthetic app-review sheet is only a static render. No real files were deleted; no duplicate content scan was run on project/user files.

## Repository and disk footprint

Remote: `https://github.com/avariceJS/disker.git`; branch: `main`; `.git` is authoritative. At resume, local `main` and `origin/main` agreed at `3f4e2d438a76b0dfb570dbc8456fd250689f1acb`. The early 2023 UTC timestamps are intentionally simulated for contribution-calendar presentation, not actual implementation dates. Keep dates transparent, preserve history, and never force-push. Five meaningful commits occupy 2023-03-06 UTC; the stop checkpoint starts 2023-03-07 UTC. Commit and publish the current developer-artifact review after final verification.

Measured workspace sizes at stop: repository 718,104 KiB total; `.git` 15,180 KiB; generated `.build` 701,456 KiB; `Sources` 424 KiB; `Tests` 200 KiB; installed app 6,040 KiB; standard app support data 100 KiB; sandboxed test app data 88 KiB. Sizes are approximate directory measurements. `.build` remains ignored and was not removed.

## Remaining work (highest priority first)

1. On a small synthetic fixture, verify sandboxed permission after relaunch, stale/missing bookmark errors, protected-folder partial coverage, and scan cancellation. Current sandboxed selected-root and same-session bookmark rescan succeeded; stale-bookmark invalidation was not exercised in the GUI.
2. Exercise duplicate verification and confirmation denial only on small synthetic fixtures; validate dry-run keeper selection and no-read denial. Never hash a personal collection.
3. Finish app-bundle selection/associated-folder and app-footprint UI walkthroughs; review dark mode, keyboard/accessibility navigation, error states, and the footprint sheet. Don’t claim coverage until actually observed.
4. Measure matched same-process idle-versus-scan resource costs. App Store distribution still needs a supported sandbox permission model, Developer ID signing, notarization, and review.
5. General cleanup recommendations and leak diagnosis are not implemented; the artifact review is a risk-aware inspection aid, not a general cleanup plan. Any future cleanup work stays read-only under current workspace instructions.

## Resume

Continue the existing Pursuing Goal. Start in `/Users/root1/Desktop/disker`, read `MISSION.md`, `AGENTS.md`, `docs/ARCHITECTURE.md`, and this handoff, verify `git status -sb`, and continue the priorities above. Launch the installed app with `open "$HOME/Applications/Disker.app"`. Quit development app processes after validation; leave no build or test processes running.
