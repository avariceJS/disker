# Architecture

## Modules

- `DiskerCore` contains `CapacityObservation`, selected-folder scanning, and bounded local JSON history.
- `DiskerApp` is a native SwiftUI macOS application with an `NSOpenPanel` for user-selected scan scope and Finder reveal.
- `DiskerCoreChecks` is a small executable check suite using temporary synthetic trees; run it with `scripts/check-core.sh`.

## Measurement contract

Volume total and available capacity are separate system-provided values. Disker prefers macOS's important-usage availability estimate when it is positive; if it is zero/unavailable, it falls back to the standard volume available-capacity value and labels that basis. Disker derives `notAvailableBytes = total - available`; it does not call this physical file usage because reservations and APFS/macOS accounting are not attributable to a path scan.

Folder scans open selected directories and descend with descriptor-relative `openat` and `fstatat`, always using `O_NOFOLLOW`/`AT_SYMLINK_NOFOLLOW` for descendants. This avoids following a child directory replaced by a symlink during a scan. Disker verifies that an opened directory still has the device/inode identity seen during enumeration and compares directory link count, modification time, and change time before and after listing. If that evidence changes, the affected subtree and root are marked partial with a separate changed-during-scan count. This catches some directory-entry races, not every write to a file after its metadata was sampled. Symlinks are not traversed; a selected symlink root is reported as incomplete. Each `(device, inode)` is counted once per selected root. Logical bytes are `st_size`; allocated bytes are `st_blocks * 512`. These estimates can diverge from reclaimable space because clones and shared blocks are not attributed. A failed metadata lookup or directory access marks that root incomplete.

Each folder scan records the selected path, observation time, logical and allocated estimates, file count, inaccessible count, excluded symlink count, and completion state. It also stores at most the 100 largest descendant-directory summaries. These are overlapping subtree totals and are explicitly presented as non-additive. A direct `.git` directory is additionally retained as a selected-root-relative measurement even when it falls outside that ranking; a `.git` file remains only a marker, and a symlink is skipped. Git metadata comparisons require the same selected root and `.git` relative path plus complete observations. A directory's coverage is incomplete when an inaccessible item or excluded symlink lies within its subtree. Hard-linked bytes are assigned to the UTF-8 lexicographically first relative file path, making sibling directory attribution deterministic.

For project context, Disker flags a selected directory when it contains a direct, non-symlink `.git` entry. A direct `.git` directory's file-tree metrics are surfaced as “Git metadata in this selected folder”; this narrow measurement is not project ownership or reclaimable-space attribution. Disker does not read a `.git` file, claim project ownership, or infer that the repository's contents are disposable. Nested repository markers are attached only to their immediate containing directory.

The scan is not an atomic filesystem snapshot. Disker checks that opened directories match the identity discovered during enumeration and compares directory metadata before and after reading each directory. Detected changes make coverage partial. This does not detect every file-content write that races with metadata sampling, and the tree is not frozen for the duration of a scan. A complete observation means no detected directory changes, metadata/access failures, or excluded symlinks; it is not a transactional snapshot guarantee.

Folder-history comparisons use the same selected path and a prior complete observation before the current observation. Directory-history comparisons additionally require the same root-relative directory path and complete root and subtree coverage in both observations. Incomplete scans are skipped and future observations are never used. An arithmetic overflow suppresses the delta. Deltas describe allocated-byte estimates, not reclaimable space.

## Persistence and privacy

The app writes at most 180 scan observations to `~/Library/Application Support/Disker/observations.json`. It stores paths and sizes, not file contents. No network or telemetry code is present. The current app asks the user to choose scope each time; it does not retain security-scoped bookmarks or silently monitor folders.

## RAM sampling

`RAMObservation` samples physical RAM size, free/active/inactive/wired/compressor page counts via Mach host statistics and converts each count using the kernel page size. It separately samples process resident sizes using `proc_listallpids`, `proc_pidinfo(PROC_PIDTASKINFO)`, and `proc_name`. Sampling is manual and point-in-time. Process exit or access restrictions are counted as unavailable. Inactive pages can be reclaimable cache; page groups are not a single additive pressure metric. Process resident size is not physical footprint. System memory pressure trends, swap, leak diagnosis, and RAM history are not implemented.

## Not implemented

Application/project ownership attribution, activity monitoring, duplicate hashing, cleanup plans, automatic scans, RAM pressure/swap trends, leak diagnosis, sandbox entitlements, signing/notarization, and an installer. These require separate measured implementations; the UI does not claim them.

## Historical commit presentation

The requested historical commit timeline begins `2023-01-01` in UTC, only after remote chronology and an owner-associated Git email are verified. These timestamps are intentionally simulated for contribution-calendar presentation; they do not represent actual implementation dates. Actual build/release timestamps and handoffs remain truthful. GitHub controls contribution attribution and display.
