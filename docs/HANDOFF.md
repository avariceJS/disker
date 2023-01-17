# Handoff

Updated: 2026-10-19.

## Product state

Disker is a native SwiftUI macOS storage utility with native `⌘O` folder-scan and `⌘⇧O` app-bundle selection commands. It reports system volume capacity separately from selected-folder logical bytes and allocated-byte estimates. Folder scans accept up to 50 selected roots and traverse metadata-only, descriptor-relative, without following symlinks; hard links are counted once per selected root. Inaccessible, changing, cancelled, or symlink-containing scans remain partial. Same-path growth uses only complete observations. History is local and bounded.

The app measures explicitly selected `.app` bundles. During that explicit selection, Security reads signed executable/resources locally and stores the declared `CFBundleIdentifier`, embedded App Groups claims, strict static-signature validation result, and signed bundle identifier with the observation. Valid signed-ID and group-claim matches receive stronger path labels; unsigned or invalid signatures retain only declared-claim evidence. Validation checks local code integrity, not Gatekeeper/notarization trust or publisher identity; no selected contents are uploaded. Shared use, current access, and exclusive ownership remain unverified. Other links remain user-selected and unverified. Sizes are never summed into an app total. The Overview highlights up to three positive allocated-byte changes from the latest complete scans of the same selected paths, shows both timestamps, and offers Finder reveal; a newer partial scan suppresses that path's older growth signal. Associated folders show change only against the previous complete measurement of that exact path. Exact-name development-storage hints are descriptive, not safety or ownership claims. Duplicate review is a separate content-reading action after confirmation; its dry-run plan requires an exact keeper and reports risk/reclaimable bytes as unknown. There is no deletion action.

The Folders page now retains up to 20 read-only security-scoped bookmarks for explicitly selected folders and application bundles. Saved scopes are local, bounded, individually removable, refreshed when a stale bookmark resolves, and usable only through a manual rescan; Disker does not access them on launch or monitor them. Clearing local history also removes these bookmarks. The bookmark file is written with owner-only permissions. App-folder association paths remain separate metadata.

## Latest verification

- Active toolchain: `/Applications/Xcode.app/Contents/Developer`, Xcode 27.1 (27A9275), Swift 6.4.0.34.1, arm64.
- `scripts/check-core.sh`: 36 checks passed, including selected-folder growth ranking and partial-scan suppression, strict signature validation of a synthetic ad-hoc app, signed-identifier persistence and matching, tampered-executable rejection, embedded App Groups claim filtering and bounds, exact/near-miss app and shared-container paths, schema migration, selected-scope bookmarks, unchanged fixture content, private file mode, and over-limit rejection without partial persistence.
- `scripts/package-app.sh`: production app built with Xcode 27.1. `plutil -lint` passed; executable is arm64. Bundle was copied to `~/Applications/Disker.app` and launched through LaunchServices; running process paths were confirmed.
- Metadata-only benchmark on the selected Disker workspace: 4,208 files, 553,665,817 logical bytes, 564,932,608 allocated estimate, 0.264 s elapsed / 0.217 s process CPU; partial only for two excluded symlinks. Selected installed app bundle: 3 files, 4,094,412 logical bytes, 4,100,096 allocated estimate, 0.001 s elapsed / CPU, complete. These are individual measurements, not general performance guarantees. One app-process sample after 44 seconds reported 181,024 KiB RSS and 0.0% CPU; it is not an interactive or workload benchmark.
- `git diff --check` passed. The installed app has not been visually reviewed for the newest growth-highlight or signature-aware attribution states: CUA returned `Computer Use server error -10005: cgWindowNotFound`; `screencapture` could not create an image from the display. Earlier Overview, Folders, History, `.git`, and RAM UI states were visually inspected; those do not validate the newest screen.
- AppleScript window enumeration did not return, so it was interrupted. Do not spend significant time troubleshooting optional UI tooling; retry visual review when a working window session is available.
- No personal folders were selected or scanned in this session. Tests use temporary synthetic fixtures.

## Safety and platform limits

Only `/Users/root1/Desktop/disker` is in scope. Never modify Brain, SRO Robot, Kingston, or real user files. Do not add deletion or claim that names, duplicate contents, age, or app associations prove data is disposable/owned. Keep the sole development branch `main`; never rewrite or force-push history.

The current Disker build is unsigned and unsandboxed, and is not App Store-ready. A signed sandboxed build still needs to validate selected-folder traversal, bookmark persistence/resolution and stale refresh, duplicate reads, local history access, and protected-folder failure states. Disker locally validates selected static code signatures, but does not verify Gatekeeper/notarization trust or publisher identity. App and group path labels do not prove current access or exclusive ownership; matching App Group data is explicitly shared. Representative interactive and scan-load resource measurements are also open. Latest visual inspection of current screens remains blocked by unavailable CUA window access; do not spend significant time on optional tooling.

## Repository and next work

Canonical remote: `https://github.com/avariceJS/disker.git`; `.git` is authoritative, `.gitmeta` history is preserved, and `main` is the only development branch. Commit and push each verified milestone to `origin/main`, then confirm local and remote HEAD match.

Next, resume visual and interactive validation of the installed app when a visible native window is available, especially app association and saved-scope/rescan flows. Continue improving evidence-based app/project attribution and growth explanations without inferring ownership from names. Keep cleanup review read-only with unknown risk/reclaimable space unless physical impact is established.
