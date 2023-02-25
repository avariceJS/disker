# Handoff

Updated: 2026-10-19.

## Product state

Disker is a native SwiftUI macOS app installed at `~/Applications/Disker.app`. It separately reports macOS-reported root-volume capacity and metadata estimates for explicitly selected folders or app bundles. Folder scans are no-follow, metadata-only, hard-link deduplicated per root, cancellable, and disclose partial coverage, races, overflow, logical bytes, and allocated-byte estimates. Local bounded history supports comparable same-path, same-volume complete-scan growth and 24-hour, 7-day, 30-day, and all-retained charts. RAM metrics are distinct; optional five-minute samples and system pressure transitions run only while Disker is active and are off at relaunch.

Application attribution is user-selected and evidence-scoped: app bundles are measured separately; declared/signed IDs and App Groups claims inform clearly qualified path suggestions; associated folders must be selected manually. Project/development clues use exact directory names, Git markers, and filename extensions only. They are not ownership, contents, or disposability claims. Duplicate verification is a separate user-confirmed content read over up to 50 selected roots; an over-limit request is rejected before reading. Its dry-run plan requires a chosen keeper, retains exact paths, selected scope, timestamp, and SHA-256 evidence, and reports risk and reclaimable space as unknown. Disker has no file-deletion action. The About page measures only Disker's own bundle and dedicated support folder.

## Latest validation

- Active toolchain: Xcode 27.1 (27A9275), Swift 6.4, arm64, at `/Applications/Xcode.app/Contents/Developer`.
- `scripts/check-core.sh`: 56 checks passed on 2026-10-19. It includes synthetic traversal, mutation, partial-coverage, history, duplicate, bookmark, persistence, arithmetic, and safety cases, plus current live capacity and RAM reads. Duplicate verification rejects more than 50 selected roots before opening any root.
- `scripts/package-app.sh` built the standard production app. Its bundle now receives an ad-hoc local signature; `codesign --verify --strict --deep` passed. The sandbox configuration also built, verified, and showed the expected App Sandbox, read-only selected-file, and app-scoped bookmark entitlements.
- The installed executable matched `.build/Disker.app`; LaunchServices opened PID 38554. CoreGraphics found one on-screen Disker window at 760×592. An unmatched 3-second idle sample showed 110,640 KiB RSS and 0.0% rounded CPU. CUA returned `-10005` (`cgWindowNotFound`), so the current pixels and interactive flows remain visually unreviewed. Do not spend significant time troubleshooting optional capture tooling.
- Latest automated live root sample: 494,384,795,648 bytes total and 443,566,108,736 available under macOS important-usage methodology. Their difference is not attributed file usage. RAM: 25,769,803,776 physical bytes; 472 processes sampled; no swap allocated.
- The installed app bundle metadata scan read no file contents and completed in 0.001 s: 4 files, 5,578,930 logical bytes, and 5,586,944 allocated estimate; `/usr/bin/du -k -s` agreed with the allocated estimate (5,456 KiB).
- Ordinary and sandboxed bundles are ad-hoc signed only. Neither is Developer ID-signed or notarized. Sandbox packaging is a configuration probe, not a validated supported build.

## Open limits and next work

Sandboxed selected-folder traversal, bookmark creation/reuse/stale refresh, duplicate reads, local history access, and protected-folder error states remain unvalidated. Representative app-driven scan performance and matched idle/resource measurements are open. Current visual review and the interactive acceptance flows need an accessible screen-capture/UI path. Automatic app-data discovery, general cleanup planning, background storage scans, continuous memory-pressure baselines, and leak diagnosis are not implemented. No real user files were deleted; keep all cleanup read-only under current workspace instructions.

## Repository

`main` is the only development branch; `.git` is authoritative; `origin` is `https://github.com/avariceJS/disker.git`. Keep verifying local and remote HEAD after each meaningful tested milestone. Historical commit dates are intentionally simulated for GitHub contribution-calendar presentation only, not actual implementation dates; actual validation dates belong in this handoff. Latest published commit is `5172671` (`Record verified duplicate limit milestone`), timestamped 2023-02-25 10:30 UTC for presentation only. Continue from the actual repository state and preserve `main` history.
