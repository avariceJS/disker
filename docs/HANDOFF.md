# Handoff

Updated: 2026-10-19 (actual session date).

## Verified checkpoint

- Native SwiftUI macOS app with real volume capacity, selected-folder metadata scans, local bounded history, same-path comparisons, Finder reveal, and on-demand RAM/process sampling.
- Folder traversal uses descriptor-relative `openat`/`fstatat` with `O_NOFOLLOW`, skips symlinks, deduplicates hard links within one selected root, and marks unreadable or selected symlink roots incomplete. Nested symlinks are currently skipped without an explicit coverage count; file-tree mutation during a scan is not reconciled. These are known accounting gaps.
- RAM process sampling uses `proc_listallpids`' process-count return value, sizes its byte buffer accordingly, and retries when the process table grows. Capacity fallback accepts only nonnegative OS values.
- `scripts/check-core.sh`: 17 synthetic and live-system checks pass, covering capacity math, metadata scan, symlink exclusion, hard links, sparse-file accounting, missing roots, cancellation, persistence, retention, explicit history reset, corrupt history recovery, safe same-path comparisons, progress, and a 300-directory fixture. `scripts/package-app.sh` builds an arm64 release app bundle and its plist passes lint. The app is unsigned and not installed. Actual GUI review and a representative large-workload/idle resource benchmark remain unverified.
- Most recent synthetic scan: 256 one-byte files and 300 empty directories, 0.004 s wall and process CPU. This tiny fixture is not a representative performance benchmark.
- `.gitignore` excludes `.gitmeta`, local `.codex` configuration, Swift/build outputs, app bundles, logs, databases, credentials, and certificates. `MISSION.md` is included in the repository.

## Repository and environment

- Canonical repository: `https://github.com/avariceJS/disker.git`; only development branch: `main`. The ordinary `.git` repo is authoritative. The previous `.gitmeta` history contained 12 meaningful commits, four each on 2023-01-01 through 2023-01-03 UTC. Those historical dates are intentionally simulated for contribution-calendar presentation and do not claim actual implementation dates (see `docs/ARCHITECTURE.md`).
- On 2026-10-19, GitHub CLI authentication succeeded as `avariceJS`; the remote had no branch or tag refs. The GitHub repository metadata reports `main` as its default branch. The full preserved history has been integrated into standard `.git` without changing any commit. Publish additively with `git push -u origin main` and verify `git rev-parse main` equals `git ls-remote origin refs/heads/main`.
- New commits use the account's GitHub no-reply author address. Existing author metadata and commit dates are preserved verbatim when importing `.gitmeta` history. Never rewrite or force-push published history.
- macOS 26 arm64 and Swift 6.3.3 are verified. `/Applications/Xcode.app` is installed (Xcode 27.1, build 27A9275), but its license has not been accepted; the active developer directory remains `/Library/Developer/CommandLineTools`. `xcodebuild -version` under `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` reports that the license must be accepted with `sudo xcodebuild -license`. Until the owner accepts it, use the working SwiftPM scripts and do not claim an Xcode build.

## Next priorities

1. Extend scanner results with truthful nested symlink/coverage reporting and mutation-race handling; preserve the no-follow boundary.
2. Add directory-level drill-down with logical and allocated estimates, incomplete coverage, and Finder reveal.
3. Add app/project attribution and RAM trends, then bounded user-approved-scope duplicate verification and read-only cleanup plans. Never delete real user data.
4. Launch the real app and verify responsive, accessible UI flows using authorized GUI automation. Measure representative scan and idle costs.
5. Add installation/uninstallation guidance, Xcode/App Store sandbox analysis, and a compact dependency inventory.
