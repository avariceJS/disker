# Handoff

Updated: 2026-10-19.

## Product state

Disker is a native SwiftUI macOS storage utility. It reports system volume capacity separately from selected-folder logical bytes and allocated-byte estimates. Folder traversal is metadata-only, descriptor-relative, and does not follow symlinks; hard links are counted once per selected root. Inaccessible, changing, cancelled, or symlink-containing scans remain partial. Same-path growth uses only complete observations. History is local and bounded.

The app measures explicitly selected `.app` bundles. Users may associate separate folders with an app, but Disker labels those links unverified and never sums their sizes as app ownership. Associated folders now show change only against the previous complete measurement of that exact path. Exact-name development-storage hints are descriptive, not safety or ownership claims. Duplicate review is a separate content-reading action after confirmation; its dry-run plan requires an exact keeper and reports risk/reclaimable bytes as unknown. There is no deletion action.

The Folders page now retains up to 20 read-only security-scoped bookmarks for explicitly selected folders and application bundles. Saved scopes are local, bounded, individually removable, refreshed when a stale bookmark resolves, and usable only through a manual rescan; Disker does not access them on launch or monitor them. Clearing local history also removes these bookmarks. The bookmark file is written with owner-only permissions. App-folder association paths remain separate metadata.

## Latest verification

- Active toolchain: `/Applications/Xcode.app/Contents/Developer`, Xcode 27.1 (27A9275), Swift 6.4.0.34.1, arm64.
- `scripts/check-core.sh`: 33 checks passed, including synthetic folder and app-bundle bookmark create/load/resolve/remove, a metadata rescan from a resolved bookmark, unchanged fixture content, private file mode, and over-limit rejection without partial persistence.
- `scripts/package-app.sh`: production app built. `plutil -lint` passed; executable is arm64. Bundle was copied to `~/Applications/Disker.app` and launched through LaunchServices; process path and bundle identifier were confirmed.
- Metadata-only benchmark on the selected Disker workspace: 4,104 files, 549,577,456 logical bytes, 561,266,688 allocated estimate, 0.285 s elapsed / 0.238 s process CPU; partial only for two excluded symlinks. Selected installed app bundle: 3 files, 3,962,764 logical bytes, 3,969,024 allocated estimate, 0.001 s elapsed / CPU, complete. These are individual measurements, not general performance guarantees.
- `git diff --check` passed. The installed app has not been visually reviewed for the newest bookmark and Applications states: CUA returned `Computer Use server error -10005: cgWindowNotFound`. Earlier Overview, Folders, History, `.git`, and RAM UI states were visually inspected; those do not validate the newest screens.
- A direct Accessibility API window query also failed with `AXError -25211` (API disabled), so the latest screen still has no visual review.
- No personal folders were selected or scanned in this session. Tests use temporary synthetic fixtures.

## Safety and platform limits

Only `/Users/root1/Desktop/disker` is in scope. Never modify Brain, SRO Robot, Kingston, or real user files. Do not add deletion or claim that names, duplicate contents, age, or app associations prove data is disposable/owned. Keep the sole development branch `main`; never rewrite or force-push history.

The current development build is unsigned and unsandboxed, and is not App Store-ready. A signed sandboxed build still needs to validate selected-folder traversal, bookmark persistence/resolution and stale refresh, duplicate reads, local history access, and protected-folder failure states. Representative interactive and scan-load resource measurements are also open. Latest visual inspection of current screens remains blocked by unavailable CUA window access; do not spend significant time on optional tooling.

## Repository and next work

Canonical remote: `https://github.com/avariceJS/disker.git`; `.git` is authoritative, `.gitmeta` history is preserved, and `main` is the only development branch. Commit and push each verified milestone to `origin/main`, then confirm local and remote HEAD match.

Next, validate the saved-scope/rescan flow in a visible native window when UI access is available. Continue improving evidence-based app/project attribution and growth explanations without inferring ownership from names. Keep cleanup review read-only with unknown risk/reclaimable space unless physical impact is established.
