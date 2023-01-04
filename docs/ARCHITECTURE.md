# Architecture

## Modules

- `DiskerCore` contains `CapacityObservation`, selected-folder scanning, and bounded local JSON history.
- `DiskerApp` is a native SwiftUI macOS application with an `NSOpenPanel` for user-selected scan scope and Finder reveal.
- `DiskerCoreChecks` is a small executable check suite using temporary synthetic trees; run it with `scripts/check-core.sh`.

## Measurement contract

Volume total and available capacity are separate system-provided values. Disker prefers macOS's important-usage availability estimate when it is positive; if it is zero/unavailable, it falls back to the standard volume available-capacity value and labels that basis. Disker derives `notAvailableBytes = total - available`; it does not call this physical file usage because reservations and APFS/macOS accounting are not attributable to a path scan.

Folder scans open selected directories and descend with descriptor-relative `openat` and `fstatat`, always using `O_NOFOLLOW`/`AT_SYMLINK_NOFOLLOW` for descendants. This avoids following a child directory replaced by a symlink during a scan. Symlinks are not traversed; a selected symlink root is reported as incomplete. Each `(device, inode)` is counted once per selected root. Logical bytes are `st_size`; allocated bytes are `st_blocks * 512`. These estimates can diverge from reclaimable space because clones and shared blocks are not attributed. A failed metadata lookup or directory access marks that root incomplete.

Each folder scan records the selected path, observation time, logical and allocated estimates, file count, inaccessible count, excluded symlink count, and completion state. It also stores at most the 100 largest descendant-directory summaries. These are overlapping subtree totals and are explicitly presented as non-additive. A directory's coverage is incomplete when an inaccessible item or excluded symlink lies within its subtree. Hard-linked bytes are assigned to the UTF-8 lexicographically first relative file path, making sibling directory attribution deterministic.

The scan is not an atomic filesystem snapshot. Files and directories can change after metadata is read or before traversal reaches them; Disker does not currently reconcile this race. A complete observation means no encountered metadata/access failures or excluded symlinks, not that the tree was frozen for the duration of the scan.

Folder-history comparisons use the same selected path and a prior complete observation before the current observation. Incomplete current scans are not compared, and incomplete previous scans are skipped. Directory summaries do not yet have historical comparisons. An arithmetic overflow also suppresses a folder delta.

## Persistence and privacy

The app writes at most 180 scan observations to `~/Library/Application Support/Disker/observations.json`. It stores paths and sizes, not file contents. No network or telemetry code is present. The current app asks the user to choose scope each time; it does not retain security-scoped bookmarks or silently monitor folders.

## RAM sampling

`RAMObservation` samples physical RAM size, free/active/inactive/wired/compressor page counts via Mach host statistics and converts each count using the kernel page size. It separately samples process resident sizes using `proc_listallpids`, `proc_pidinfo(PROC_PIDTASKINFO)`, and `proc_name`. Sampling is manual and point-in-time. Process exit or access restrictions are counted as unavailable. Inactive pages can be reclaimable cache; page groups are not a single additive pressure metric. Process resident size is not physical footprint. System memory pressure trends, swap, leak diagnosis, and RAM history are not implemented.

## Not implemented

Application/project ownership attribution, activity monitoring, duplicate hashing, cleanup plans, automatic scans, RAM pressure/swap trends, leak diagnosis, sandbox entitlements, signing/notarization, and an installer. These require separate measured implementations; the UI does not claim them.

## Historical commit presentation

The requested historical commit timeline begins `2023-01-01` in UTC, only after remote chronology and an owner-associated Git email are verified. These timestamps are intentionally simulated for contribution-calendar presentation; they do not represent actual implementation dates. Actual build/release timestamps and handoffs remain truthful. GitHub controls contribution attribution and display.
