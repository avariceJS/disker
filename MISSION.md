# DISKER — AUTONOMOUS ENGINEERING MISSION

**Mission:** Design, build, test, install, and continuously improve Disker, a polished, trustworthy, native macOS application that makes disk usage and memory behavior understandable, tracks changes, reveals waste, and enables safe, informed cleanup.

**Operating system:** A recently factory-reset MacBook Pro with Apple Silicon.

**Local user:** `root1` (`/Users/root1`).

**Repository:** `https://github.com/avariceJS/disker.git`.

**Implementation language:** English for source code, developer documentation, agent instructions, architecture, and handoffs. Communicate progress and the final report to the owner in Russian.

**Execution mode:** Autonomous, goal-driven, multi-agent development, using actual supported capabilities rather than simulated agents or imaginary features.

**Product standard:** A serious macOS product with a realistic path toward commercial distribution and the Mac App Store. No superficial prototype, fake dashboard, inert buttons, or inflated completion claim.

---

## 0. YOUR MANDATE

You are responsible for the product outcome, not merely for following a checklist.

The owner has given you the business problem, desired operating model, and safety boundaries. You must supply the missing product thinking, architecture, engineering judgment, and execution. Choose sensible solutions independently.

The owner is leaving the machine running overnight. Make substantial, verified progress without repeatedly requesting decisions about ordinary engineering details. Start implementing promptly. Continue through productive iterations until the acceptance criteria are met or a genuine blocker prevents further safe work.

Treat the mission as a coherent product-building effort:

1. Understand the real needs and the macOS platform.
2. Prepare a clean, reproducible development environment.
3. Design a small, understandable product architecture.
4. Deliver the first real, launchable native application early.
5. Build an accurate measurement and attribution engine.
6. Add usable analytics, history, insights, and controlled cleanup.
7. Test functionality, correctness, responsiveness, and safety.
8. Review the actual visual interface and user flows.
9. Integrate, commit, push, and continue.
10. Leave a precise, compact handoff if execution is interrupted.

**Value and correctness outrank feature counts, commit counts, agent counts, and line counts.** A smaller coherent feature that works reliably is more valuable than several unfinished screens.

Do not spend the night writing plans or documentation instead of producing working software. Do not call an unfinished application “production-ready” merely because it compiles.

---

## 1. THE USER PROBLEM

Before the factory reset, the owner's internal SSD had roughly 500 GB occupied. It was not clear which applications, projects, databases, containers, images, logs, caches, backups, and transient artifacts were responsible.

macOS and development tools naturally store related information in different places. A single program might have a bundle in `/Applications`, preferences under `~/Library/Preferences`, mutable data in `~/Library/Application Support`, caches, logs, helper processes, and external dependencies elsewhere.

The owner wants **one comprehensible control center**, not necessarily one physical directory.

The owner should be able to answer these questions within seconds:

- How much disk space is truly available and occupied?
- What are the largest contributors to that usage?
- Which applications own which files, and how confidently is ownership known?
- Which application or project grew significantly today or this week?
- What caused the most recent loss of free space?
- Where are the associated files on disk?
- Which files appear abandoned, duplicated, or safely reproducible?
- Which applications are no longer used, and what remains after uninstalling them?
- What is a conservative estimate of space that could be reclaimed?
- Which cleanup operations would erase unique or irreplaceable information?
- Which directory, service, or process is growing abnormally?
- Is there evidence of abnormal RAM growth or a potential memory leak?
- Why do different macOS storage displays disagree?
- What is known, estimated, or inaccessible?

The user should not have to understand APFS, Unix paths, containers, inode semantics, `du`, or Activity Monitor to benefit from the product. Technical details must remain available when requested.

**Core product promise:** Make storage understandable, explain changes, and enable informed action without compromising personal data.

### Disk vs. memory

Treat two resources separately:

- **SSD storage** is the primary product domain: files, allocated blocks, snapshots, capacity, usage, ownership, growth, and cleanup.
- **RAM** is a secondary, distinct product domain: system pressure, process memory, swap, trends, and possible leaks.

Never conflate storage consumption with process memory usage. Do not display both with an ambiguous “Memory” label.

---

## 2. THINK LIKE A PRODUCT TEAM

Act as a strong interdisciplinary engineering group:

- Product architect: user needs, differentiation, sensible scope, workflows.
- Lead native macOS engineer: Swift, SwiftUI, AppKit, system integration.
- Filesystem engineer: APFS, capacity, traversal, accounting, permissions.
- Data/analytics engineer: snapshots, deltas, history, efficient persistence.
- UX designer: information hierarchy, clarity, states, polished interaction.
- Security/privacy reviewer: safe attribution, consent, deletion boundaries.
- QA/performance engineer: rigorous scenarios, correctness, resource costs.

You own product decisions within the boundaries in this document. Research relevant system APIs and product patterns when helpful, but avoid getting trapped in competitive analysis.

Infer and propose valuable capabilities beyond the examples listed here when justified by real user value. Do not interpret each suggestion as a mandatory widget or screen.

**Maximum user value, minimum interface complexity.**

A professional interface is not an endless settings panel, a dense terminal dashboard, or a list of obscure metrics. It surfaces the most important observations immediately and reveals details progressively.

Every screen must explain something, enable an action, or both.

---

## 3. A REAL NATIVE MACOS APP

Build a proper `.app` that the owner can launch from Finder, Spotlight, Launchpad, or the Applications folder, without running a terminal command.

Prefer:

- Swift.
- SwiftUI.
- Foundation and native system frameworks.
- AppKit where macOS behavior demands it.
- Platform-supported system APIs and documented integration points.

A browser-based local dashboard is not an acceptable substitute. Neither is a terminal-only Python script, an HTML mockup, or Electron adopted without a compelling technical reason.

If an alternative implementation is objectively better, Sol must document the trade-off and preserve true desktop application quality. The default choice remains native Swift.

### macOS experience

Deliver, to the extent supported and implemented:

- Native window behavior, menus, dialogs, keyboard shortcuts, and context menus.
- Clean navigation appropriate for a macOS utility.
- Light and dark themes with good contrast.
- Crisp Retina rendering and good typography.
- Resize-friendly content, sensible minimum dimensions, and correct scrolling.
- Localization-friendly strings; user-facing Russian is welcome if well supported.
- Accessibility labels, keyboard navigation, and appropriate VoiceOver support.
- Clear first-run onboarding and permission explanations.
- Empty, loading, partial-result, cancellation, and failure states.
- Background work that never freezes the interface.
- Native Reveal in Finder, Quick Look, and file selection behavior where useful.
- Reopen, relaunch, update, and uninstall behaviors that make sense to a Mac user.
- A user-friendly installed application rather than a development-only process.

Do not put screenshots, progress bars, or controls in the product unless they correspond to functioning software.

### Mac App Store trajectory

Architect with eventual commercial release in mind:

- Understand App Sandbox boundaries and user-selected file access.
- Use least-privilege permissions and clear permission disclosures.
- Identify differences between a sandboxed App Store edition and an extended-capability direct-distribution edition, if necessary.
- Account for future code signing, notarization, entitlements, privacy disclosures, and review requirements.
- Do not claim App Store approval, signed distribution, or compliance without actually verifying it.
- Do not build a permanent privileged agent unless necessary, supported, and approved.

---

## 4. FIRST-OPEN EXPERIENCE AND PRIMARY DASHBOARD

The main view should answer “What is taking my space, and what changed?” within seconds.

Show only the metrics that matter most, for example:

- Internal drive capacity and available/occupied space.
- Change in available space since the previous usable observation.
- A breakdown of meaningful usage categories.
- Top space consumers among apps, projects, and large directories.
- The fastest growing attributable entities.
- Notable anomalies and potentially reclaimable space.
- Current data freshness, scan coverage, and confidence.

Example insight copy, using **real measured values only**:

- “Cursor support data increased by 4.2 GB over the last day.”
- “This project grew by 11 GB this week.”
- “1.8 GB of byte-identical candidate duplicates were found.”
- “The last full scan could not access certain protected folders.”

Do not fabricate a populated timeline on first launch. If no historic measurements exist, clearly show that time-based analysis will become available after subsequent observations.

Prefer a dashboard that is calm, legible, and actionable, with drill-down rather than excessive charts.

Potentially useful visual patterns include layered storage breakdowns, a carefully designed treemap, ranked lists, sparkline trends, and a small set of prioritized insights. Choose what genuinely helps.

---

## 5. APPLICATION OWNERSHIP AND FOOTPRINT

A user should select an installed application and understand its approximate full footprint, not merely the `.app` bundle size.

Investigate, where accessible and justified:

- Primary application bundle and metadata.
- Confirmed application support directories.
- Application-specific caches.
- Logs.
- Preferences.
- Containers and group containers.
- Saved application state.
- Helper tools and extensions when their relationship is well established.
- Versioned support data and derived assets.
- Associated developer or package-manager state when unambiguously attributable.

Explain each association. Do not assign a folder solely because the names look similar.

Mark attribution confidence, such as confirmed, probable, shared, or unknown. Shared data must never be silently charged as exclusively owned by one app.

Expose actual paths in a details view, with an action to reveal items in Finder where permitted.

Offer a sensible uninstallation footprint view that explains what is definitely removable, what is optional, what is shared, and what may contain irreplaceable user state.

When an app is absent but suspected data remains, classify this as a **candidate orphan**, not a confirmed safe deletion, unless the evidence is strong.

---

## 6. DEVELOPMENT PROJECT INTELLIGENCE

The machine will host complex software development and machine-learning projects. Disker must treat development data as a first-class category.

Recognize or explain, when present:

- Git repositories and `.git` storage.
- `node_modules`, npm/pnpm/yarn caches, lockfiles, toolchains.
- Python environments, wheels, package caches, and build products.
- Xcode DerivedData, SwiftPM caches, archives, and simulator data.
- Docker images, build cache, containers, and volumes.
- SQLite databases, associated WAL files, and other local databases.
- ML models, checkpoints, embeddings, and datasets.
- Log rotations, crash logs, trace files, and large generated reports.
- Temporary benchmark outputs and staged processing folders.
- Sparse disk images, mounted virtual disks, and recovery rehearsal artifacts.
- Downloaded installers, SDKs, and dependency bundles.
- Archives, old project snapshots, and duplicated backups.

Do not automatically call a development artifact disposable. A compiled cache can often be regenerated; a database, model checkpoint, or unique training corpus may not be.

Project intelligence should allow the owner to drill down by project and by type of artifact, compare sizes over time, and understand which parts could theoretically be regenerated.

Consider future project-level policies and exclusions, but avoid assuming project management authority over the contents of Brain or SRO Robot.

---

## 7. ACCURATE STORAGE ACCOUNTING

Storage measurements must be technically honest.

Study and account for macOS/APFS behavior, including:

- Physical internal devices, APFS containers, volumes, and shared capacity.
- Logical file size vs. allocated physical storage.
- Clones, copy-on-write data, hard links, sparse files, and symlinks.
- Snapshot storage and the limits of attributing it to paths.
- Purgeable space and macOS-managed storage.
- Shared file or container accounting.
- Package bundles vs. constituent files.
- Multiple mounted volumes and external volumes.
- Permission-restricted folders and partial coverage.
- The gap between recursive directory totals and global used capacity.
- Race conditions while the file tree is changing.

Use a well-defined accounting model. Prevent double-counting where possible and surface uncertainty where not possible.

A file tree sum does not necessarily reconcile to the exact physical SSD usage shown by macOS. Never imply otherwise.

Display:

- The metric's unit and meaning.
- Observation timestamp.
- Completeness or coverage.
- Actual vs. estimated values.
- Unattributed/unknown space rather than invented assignments.

Do not turn permission failures into “0 bytes.”

Compare results to system tools and documented APIs, investigate mismatches, and state limitations plainly.

A credible answer is more important than an impressively precise-looking false number.

---

## 8. HISTORY, CHANGE DETECTION, AND TRENDS

Persist observations and make meaningful comparisons possible over time.

Useful scopes include:

- Total internal storage.
- Storage categories.
- Individual applications and associated directories.
- Development projects.
- Explicitly watched folders.
- RAM and process measurements as a distinct subsystem.

Provide appropriate time ranges as the history accumulates: hours, days, weeks, and months.

Detect meaningful changes and identify which entities most plausibly explain them. Be careful not to mistake incomplete scans or detached volumes for real deletion or growth.

Store measurements efficiently and predictably. Consider bounded retention, downsampling, aggregation, and indexing without premature complexity.

Allow users to inspect or clear Disker's own history.

### Monitoring methodology

Choose a hybrid strategy appropriate to macOS:

- Light, cheap observations at a reasonable cadence.
- Event-driven invalidation or selective updating where reliable.
- Incremental rescanning when practical.
- Full scans only when justified or requested.
- Manual refresh and scan cancellation.
- Clear freshness and coverage status.

Do not claim byte-by-byte real-time provenance of every filesystem write. Detect changes honestly at the available resolution and interval.

If change notifications can miss events, the design must handle reconciliation.

---

## 9. INSIGHTS, ANOMALIES, AND RECOMMENDATIONS

Generate explanations and ranked recommendations that genuinely help free space or investigate unexpected growth.

Examples:

- A particular application directory grows abnormally fast.
- A developer cache has grown very large.
- An installer appears abandoned.
- Several identical large files exist.
- A stale build output can probably be regenerated.
- An inactive project has substantial local data.
- A log is rapidly accumulating.
- A virtual disk is still mounted and consuming local backing storage.
- Free internal space is approaching a conservative warning threshold.

For every recommendation, show:

- Evidence.
- Affected paths or entities.
- Observed size and potential gain, with uncertainty.
- Confidence and risk.
- A clear next action, where one exists.

Avoid false positives and excessive notifications. Users should trust an alert because it is meaningful, not because the software produces many alerts.

Do not infer that a file is unnecessary merely because its modification time is old. Last modified, last accessed, last opened, and actual usefulness are different concepts.

Anomaly detection should initially favor interpretable rules and sound statistics. Add complexity only if it improves empirical results.

---

## 10. DUPLICATES AND ABANDONED DATA

Implement a serious duplicate-file workflow, not just matching names and sizes.

A sensible candidate pipeline may include cheap filters and final content verification, but the team should choose the safest, most performant implementation.

Account for:

- File size and content digest.
- Symlinks and hard links.
- APFS clones and physical-space sharing.
- Resource-intensive hashing of large datasets.
- Changing files during analysis.
- Protected directories and files that cannot be read.
- App bundles and versioned dependencies.
- Duplicates across internal and external volumes.
- Known shared dependencies and legitimate redundant backups.

Two byte-identical files are not automatically safe to delete, and their logical sizes may not equal reclaimable physical space.

Do not hash entire personal file collections without a sensible permission and scope model. Metadata-only scanning is the default where feasible; reading file content for confirmation must be limited to a user-approved scope or other clearly authorized operation.

For potential stale/abandoned data:

- State why an item is considered potentially inactive.
- Distinguish observed activity from weak heuristics.
- Preserve the option to inspect it manually.
- Never imply that age alone proves disposability.

---

## 11. SAFE CLEANUP AND COMPLETE APP REMOVAL

This is a flagship workflow. The owner wants to remove unwanted applications “with their roots” while protecting unique data.

For any cleanup candidate, produce a reviewable, explicit plan:

- Exact target paths or confirmed objects.
- Ownership evidence and scope.
- Logical and expected reclaimable sizes.
- Reproducibility or restoration options.
- Shared dependencies or other consumers.
- Risk of losing unique state.
- Items that are excluded and why.
- A clear distinction between cache cleanup and complete uninstall.

At minimum, distinguish:

1. Reproducible and low-risk data.
2. Unique or user-generated data.
3. Shared or multi-owner data.
4. Unknown or low-confidence data.

**Default behavior is read-only analysis and dry-run.**

Real destructive operations require a distinct, explicit, contemporaneous confirmation by the owner in the app. No generic overnight permission or goal-following instruction is sufficient.

Prefer reversible workflows, including the system Trash, when technically applicable. Do not silently bypass Trash.

Important protections:

- Never delete based on a vague filename or guessed association.
- Avoid unconstrained `rm -rf` operations.
- Check symlink traversal and path containment.
- Revalidate targets before acting (TOCTOU resistance).
- Protect other mounted volumes and user-selected exclusion paths.
- Do not erase Keychain, protected macOS state, recovery materials, or unknown databases.
- Do not erase shared resources because one related app was removed.
- Never treat an unknown result as safe.
- Keep errors and partial outcomes visible.

During this overnight development mission, **do not delete real user files at all**. Implement and validate destructive workflows exclusively against small, clearly identified, synthetic test fixtures under the project test area.

A professional cleaner is one that knows when *not* to delete.

---

## 12. MEMORY / RAM OBSERVABILITY

Provide a distinct, useful RAM view, secondary to SSD intelligence.

Consider:

- Physical RAM capacity and current pressure.
- System-wide memory pressure trend.
- Process memory metrics available to an unprivileged app.
- Memory-hungry processes and their associated applications.
- Swap utilization when supported and measurable.
- Long-lived growth trends and potential leak indicators.

A memory leak cannot be established merely because a process's memory grows during a short observation. Distinguish caches, working-set growth, load variation, and suspicious sustained trends.

Use cautious language: “possible abnormal growth” or “investigate this process,” not “confirmed leak” without compelling evidence.

Where process-level metrics are unavailable, do not invent them or secretly escalate privileges.

Keep RAM charts and storage charts visually and semantically separate.

---

## 13. NOTIFICATIONS AND BACKGROUND BEHAVIOR

Useful notifications may include:

- Very low free space.
- Abnormal growth in a tracked directory or app.
- A major change since the last observation.
- A repeated growth pattern worth investigating.

Avoid noisy alerts, duplicate messages, and broad default surveillance.

Design a lightweight monitor that conserves CPU, memory, disk I/O, and battery life.

Allow the owner to:

- Configure or disable alerts.
- Change scan frequency.
- Pause and resume monitoring.
- Exclude selected paths.
- Inspect alert evidence.
- Stop a scan.

If closed-window monitoring requires a LaunchAgent/helper, implement it only with appropriate consent and a simple uninstall path. Do not silently register persistent or privileged services during the overnight development session.

The app should measure and expose its own storage footprint and avoid becoming a large source of cache or logs.

---

## 14. UI / UX QUALITY BAR

Design for a normal Mac owner, not a filesystem forensic analyst.

Prioritize:

- Intuitive navigation.
- Clear visual hierarchy.
- Focus on changes and actionable findings.
- Calm macOS-native design.
- Consistent terminology.
- Excellent typography, spacing, and contrast.
- Progressive disclosure of technical details.
- Concise, human-readable explanations of risk and confidence.
- Accessible interactions and keyboard support.

A user should understand the main questions immediately:

1. What occupies my SSD?
2. What changed recently?
3. Where does it live?
4. What can I safely do about it?

Use the main screen sparingly. Put power-user details in inspector panels and drill-down views.

Choose helpful visualizations; do not overload the interface with charts.

Consider useful macOS-specific touches such as a menu bar overview, Finder integration, quick search, keyboard commands, and native system notifications, but implement only features that deliver clear value.

### Real usability verification

Use accessible screenshot/GUI automation or computer-control capabilities when genuinely available to inspect and interact with the application. These permissions must be granted through macOS mechanisms; never bypass them.

Manually or automatically verify critical flows and fix broken layouts, clipped labels, stale values, misleading loading indicators, unresponsive controls, and confusing empty states.

Do not report visual QA as completed if nobody or no real automation actually performed it.

---

## 15. PREPARE THE CLEAN DEVELOPMENT MACHINE

The user has explicitly authorized the installation of normal tools required to implement the project.

First inventory what already exists. Install missing essentials from official, trusted sources using supported packaging methods:

- Apple Command Line Tools and Git.
- Homebrew if useful and absent.
- Supported Swift toolchain / Xcode as required by the actual build.
- Python 3 and a safe way to manage isolated environments.
- Supported Node.js LTS and npm if necessary for this mission or the basic development environment.
- Build, test, format, and analysis tools that materially help.

Install only justified dependencies, not a kitchen sink of databases, container engines, SDKs, and global packages “for later.”

Preserve the system Python. Prefer per-project environments and reproducible dependency declarations.

Document exact versions, installation locations, update methods, and uninstall methods.

Avoid unaudited remote shell scripts, unnecessary privilege escalation, disabling macOS security, or changing Apple Account settings.

If a tool installation requires user interaction, authentication, a developer account, or a large download requiring confirmation, keep other independent tasks progressing. State the blocker precisely rather than idling silently.

Before any installation that might interfere with the future Brain recovery, inspect the recovery instructions if accessible; otherwise choose isolated and conservative installations and record assumptions.

### Available permissions

The owner also authorizes ordinary use of available GUI and desktop-control tools for development, installation, and UX testing. This does **not** bypass operating-system approval dialogs, permissions, passwords, secrets, or the destructive-operation approval boundary.

---

## 16. WORKSPACE ORGANIZATION AND MACHINE INVENTORY

The Mac has just been reset. Do not recreate an untraceable sprawl.

Use a predictable working location, preferably:

`/Users/root1/Developer/disker`

Follow standard macOS and package-manager directory conventions. In particular, do not relocate Homebrew or application support data arbitrarily in pursuit of an artificial “single folder” goal.

Create a clear organization for data that **we** control, such as project source, build artifacts, small test fixtures, app-owned data, and diagnostic exports.

For data controlled by macOS or third-party applications, maintain an inventory that points to its real location rather than unsafe relocations or symlink hacks.

### Machine Inventory

Record relevant installed development dependencies in a concise, maintained inventory that includes:

- Name and version.
- Purpose.
- Executable location.
- Package manager or source.
- Related cache/data locations if known.
- How to update.
- How to uninstall.
- Whether it is a shared dependency.
- Whether Disker installed it.

This can be part of project documentation or a generated manifest. Avoid building an unnecessary separate management platform merely to hold this information.

Keep temporary tests small. Do not leave mounted rehearsal disks, generated multi-gigabyte fixtures, forgotten background processes, or duplicate installations.

Provide simple commands or UI paths that let the user understand Disker's own footprint and remove its installation, support files, and monitoring components.

---

## 17. PROTECT BRAIN, SRO ROBOT, AND KINGSTON

This machine will later restore two important projects:

- **Brain**, a substantial machine-learning and research system with a prepared recovery kit, pinned environments, and original expected filesystem locations.
- **SRO Robot**, an important business automation project with its own source history and recovery path.

A separate Kingston external drive contains critical backup and recovery artifacts.

Mandatory constraints:

- Do not alter, erase, format, rearrange, or “clean” Kingston.
- Do not run Brain or SRO restoration as part of this mission.
- Do not modify their repositories, state, databases, or expected path conventions.
- Do not rewrite their runtime configuration to fit Disker.
- Do not create global toolchain conflicts that complicate their future recovery.
- Do not inspect or publish their secrets.
- Do not classify their critical data as safe-to-delete merely because some directories are old or large.

When these projects eventually exist locally, Disker may observe their storage footprint within the owner's authorized scope, but it must not become an automatic manager of their data.

Preserve `/Users/root1` as the existing user home; do not change `HOME`, UID, account configuration, system volumes, or protected system layout.

---

## 18. MULTI-AGENT OPERATING MODEL — SOL-6 HIGH / LUNA-6 HIGH

The desired operating hierarchy is based on the owner's Brain engineering workflow.

### Sol-6 High — chief orchestrator

Sol is responsible for:

- Product intent and acceptance criteria.
- Architecture and major trade-offs.
- Scope and prioritization.
- Work decomposition and assignment.
- Stable subsystem interfaces and contracts.
- Integration decisions and conflict resolution.
- Review of quality, safety, and performance.
- Overall project state and mission completion.

Sol should use engineering leadership rather than doing all implementation personally.

### Luna-6 High — execution agents

Luna workers are responsible for:

- SwiftUI and AppKit implementation.
- Filesystem and APFS-related engineering.
- Data model, persistence, and analytics.
- Application attribution and project intelligence.
- Trend analysis, insights, and duplicate detection.
- Safe cleanup design and validation.
- RAM observability.
- Unit, integration, safety, and performance testing.
- Debugging and focused iteration.

Use multiple Luna workers **where actual parallelism helps**. Build a productive agent team, not an uncontrolled swarm.

Assign independent tasks with clear ownership. Avoid concurrent edits to the same files and conflicting assumptions about data models. Sol controls integration and contract changes.

The number of agents must be constrained by available tool support, machine capacity, work dependencies, context limits, and actual throughput. More agents do not automatically mean better work.

### Actual model availability is mandatory to verify

Investigate the installed Codex CLI and its supported model/delegation interface.

If `sol-6-high` and `luna-6-high` are real, available model identifiers, use them in the intended roles.

If not, **do not invent configuration files, pretend unavailable models were selected, or fake subagents**. Preserve the desired planner/implementer separation using the best actually supported model and reasoning settings. Report what was genuinely available and used.

If only a single Codex agent can run, use rigorous internal planning and staged execution, but never call it a real multi-agent system.

### Coordination rules

- High cohesion, low coupling.
- Explicit interface contracts.
- Small integration surfaces.
- Stable, reviewable deliverables.
- No overlapping uncoordinated file ownership.
- Cross-component verification before merging changes.
- Architecture review for changed contracts.
- Transparent progress and honest limitations.

---

## 19. PURSUING GOAL — CONTINUOUS AUTONOMOUS EXECUTION

The requested operating mode is **Pursuing Goal**, with continuous progress until the target is reached or a genuine blocker is encountered.

Verify whether the current Codex environment supports a real goal-management command or persistent goal mode. If it supports `/goal`, activate and confirm it properly. If it does not, use the best supported long-running autonomous workflow and clearly state the limitation.

Writing “Pursuing Goal” in `AGENTS.md` is not sufficient evidence that a persistent goal mechanism has been activated.

The working loop is:

**Understand → Plan → Delegate → Implement → Verify → Review → Integrate → Evaluate → Continue.**

Use rolling-wave planning. Plan near-term tasks in detail and later tasks at an appropriately higher level. Reassess as results appear.

Do not stop simply because one screen is done, one build succeeds, a test suite passes, a commit is created, or a progress note has been written.

Continue with the next highest-impact task as long as execution is supported and safe.

However:

- Never equate continuous work with unrestricted destructive authority.
- Do not bypass prompts that require the owner to approve a dangerous operation.
- Do not run infinite trivial work to appear active.
- Do not spend resources without purpose.
- Do not claim work continued during times when the agent or machine was stopped.
- Stop and report a genuine blocker when no safe independent work remains.
- Preserve a useful recovery handoff at natural checkpoints.

The owner may be sleeping. Favor decisions that do not require input and leave interactive requests clearly marked if encountered.

---

## 20. OVERNIGHT AUTHORIZATION AND SAFETY LIMITS

The owner explicitly authorizes autonomous work on this project, including:

- Creating the Disker project and Git repository.
- Installing reasonable development dependencies.
- Writing and editing Disker's source files.
- Compiling and launching the app.
- Running non-destructive tests.
- Performing read-only inspection of machine storage metadata.
- Measuring sizes, system metrics, and performance.
- Using GUI tools where available and properly authorized.
- Taking screenshots of Disker for layout testing when supported.
- Creating small synthetic test fixtures.
- Running targeted refactoring and corrections in Disker's own code.
- Creating meaningful Git commits and pushing them to the designated repository.
- Coordinating genuinely available subordinate agents.

The owner has **not** authorized unattended:

- Deletion or modification of real user data.
- Modification of existing unrelated projects.
- Touching the Kingston backups.
- Erasing volumes or partitions.
- Changing security protections or protected OS settings.
- Reading passwords, private keys, or secret-bearing data.
- Uploading personal files to external services.
- Publishing user data in logs or repositories.
- Creating paid cloud resources or purchases.
- Shipping or publicly publishing the application.
- Persistent privileged services or silent background surveillance.

Read-only metadata analysis is allowed. If an operation requires a new macOS privacy grant, describe it and proceed within the existing permission scope until the owner can decide.

No fake “approval by silence.”

---

## 21. GITHUB — REQUIRED REPOSITORY AND BRANCH POLICY

**The canonical remote is:**

`https://github.com/avariceJS/disker.git`

**The only development branch is:** `main`.

GitHub is the authoritative published record of Disker. Do not create extra local or remote development branches or persistent worktrees. If parallel agents cannot collaborate safely under this branch policy, coordinate via disjoint file ownership and sequential integration rather than violating the owner's rule.

At the start:

1. Inspect the working tree and existing remote configuration.
2. Initialize or reuse the correct local repository.
3. Set or verify `origin` points to the URL above; do not duplicate it.
4. Inspect the remote before creating or pushing commits.
5. Preserve any existing commits and repository files.
6. Verify the Git author identity and an email associated with the owner's GitHub account, without exposing private account information.
7. Configure `.gitignore` before adding generated files.

Never force-push, rebase or rewrite published history, delete repository content to simplify setup, or push to another project repository.

### Meaningful, frequent publication

Make cohesive, reviewed commits after reasonable increments of real implementation. Each commit should represent actual code, tests, configuration, UX work, or documentation with an intelligible purpose.

Do not accumulate a large unpublished backlog. Push promptly to `origin/main` after verified increments; at minimum, after each cohesive milestone and whenever work might be interrupted. Local commits are mechanically necessary before pushing, but they should not remain unpublished without a real technical reason.

Do not pad commits with whitespace changes, empty commits, generated noise, or meaningless file churn.

Exclude secrets, `.env` files, credentials, local state, user-specific files, test datasets, caches, dependencies, build outputs, app history databases, screenshots not deliberately selected for the repository, and bulky generated artifacts.

Verify that the remote has received new commits, not merely that a local `git commit` succeeded. If authentication or remote protection blocks pushing, preserve work locally and report the exact blocker. Never destroy unpushed work.

### REQUIRED SPECIAL HISTORICAL CONTRIBUTION TIMELINE

The owner explicitly requests that the **new Disker project's commit timestamps** start at **January 1, 2023**, then advance sequentially by one calendar day after every **2–5 meaningful commits**. This is intentional *backdating for a GitHub contribution-calendar presentation*, not a claim that Disker was actually developed on those dates.

Implement this request **only within the new Disker repository** and only for genuinely distinct, verified work produced during the current development effort.

Detailed rules:

1. Initialize the historical timeline at `2023-01-01` in a stable, explicitly chosen timezone; document the timezone.
2. Make 2–5 substantive, coherent commits attributed to that calendar date.
3. After completing that day's set, advance the assigned date by exactly one day.
4. Repeat chronologically as far as actual verified development naturally progresses, never manufacturing changes merely to advance the calendar.
5. Select a varied daily count in the requested range, but do not split logical work into nonsensical microcommits. Engineering quality wins if these constraints conflict.
6. Use an author email genuinely associated with the owner's GitHub account so legitimate contributions can be attributed correctly.
7. If backdating is technically supported and does not conflict with remote history, set both author and committer timestamps intentionally and consistently for the selected date. Keep chronological ordering within each date.
8. Make real pushes to GitHub throughout the night. Do not defer all commits until the end, and do not create purely local historical branches.
9. **Never rewrite an existing remote history** to satisfy the date pattern. If the repository already has published 2026 commits or another chronology, inspect it and choose a safe additive approach. Record any incompatibility rather than using force-push or destroying existing work.
10. Do not alter dates in Brain, SRO Robot, or any other repository.
11. Do not create fake previous work, fake reviews, fake contributors, or false claims about when the software was invented, built, or used.
12. Transparently disclose in the project's developer documentation that the early historical Git commit timestamps are **intentionally simulated for contribution-calendar presentation** and do not represent the actual implementation dates. Keep actual build/release metadata and engineering handoffs dated truthfully.
13. Do not promise a particular GitHub heatmap outcome: GitHub controls contribution attribution and display rules.

The owner wants to fill part of the 2023 calendar **through the real development work performed tonight**, not generate thousands of throwaway commits. The backdated timeline must never compromise application quality, traceability, real release timestamps, or repository integrity.

If the two constraints conflict — a meaningful verified commit versus an arbitrary 2–5-per-day quota — **do not fabricate code changes**. Save the real state, explain the conflict, and keep the implementation clean.

### Final repository checks

Before the last report, verify:

- Only the expected `main` branch is used.
- `origin` is correct.
- No secrets or heavy generated data were committed.
- Recent commits represent tested work.
- Commits were pushed successfully.
- The working tree status is understood.
- `main` and `origin/main` agree, except for explicitly disclosed blockers.

---

## 22. PROJECT INSTRUCTIONS AND COMPACT MEMORY BANK

Future agents must be able to continue without rediscovering everything. Avoid creating dozens of overlapping Markdown documents.

A compact set is preferred:

- `AGENTS.md`: project-specific agent behavior, boundaries, roles, and workflow.
- `README.md`: what Disker does, how to build/run/install/use it.
- `docs/ARCHITECTURE.md`: important architecture, data/accounting contracts, and key design decisions.
- `docs/HANDOFF.md`: current goal, verified progress, known limitations, blockers, and next best actions.

Add documentation only when information genuinely requires a separate reference. Consolidate obsolete notes rather than endlessly appending diaries.

Maintain short, accurate state at checkpoints:

- What exists and actually works.
- Which tests were run and passed.
- What was not tested.
- Dependencies and assumptions.
- Open problems and regressions.
- Immediate next steps.
- Real operational state of the agent workflow.

Use English for all agent-facing material. Report to the owner in Russian.

### Global instructions

Keep `~/.codex/AGENTS.md` limited to universal rules for engineering quality, safe autonomy, and organization. Keep Disker-specific requirements in the repository's own `AGENTS.md`.

Inspect any existing instructions and preserve useful content rather than blindly overwriting them. Do not make global instructions interfere with Brain or SRO Robot.

Do not let maintaining Memory Bank become the primary activity. Source code and tests remain the durable truth for behavior.

---

## 23. GIT ENGINEERING STANDARDS

Code should feel professionally maintained, not generated for the sake of volume.

- Follow a coherent project style.
- Use meaningful names, clear module boundaries, and testable interfaces.
- Avoid unnecessary layers and abstractions.
- Do not refactor unrelated user projects.
- Keep code comments useful and sparse; do not narrate obvious operations.
- Prefer focused changes over giant speculative rewrites.
- Keep third-party dependencies few and justified.
- Use reproducible build and development configuration.
- Surface failures instead of silently ignoring them.
- Keep security-sensitive logic easy to review.
- Do not use boilerplate code or empty files to give an illusion of progress.

Treat tests, product behavior, and observable results as stronger evidence than confident agent summaries.

---

## 24. TESTING PLAN AND EVIDENCE

Build a credible automated and manual QA strategy appropriate to the real architecture.

### Storage correctness

Cover, as applicable:

- Basic directory traversal and file-type aggregation.
- Application and project attribution.
- Logical vs. allocated size accounting.
- Hard links, symlinks, loops, and package bundles.
- Sparse files and APFS clones when feasible.
- Unreadable directories and partial scans.
- Large trees and cancellation.
- File creation, change, and deletion during scans.
- Mount/unmount of volumes.
- External volumes and protective exclusions.
- Repeated scans and snapshot comparisons.
- Deltas across incomplete observations.
- Timestamp changes and metadata ambiguity.
- Duplicate verification and false-positive prevention.
- Expected reclaimable space estimates with uncertainty.

### Cleanup safety

Cover:

- Dry-run plan generation.
- Ownership and shared-data recognition.
- Unique user-data warnings.
- Path containment and symlink attacks.
- Stale plans and changed files.
- Deleted/missing targets.
- Cross-volume operations.
- Partial failures and cancellation.
- Synthetic confirmation and Trash behavior where safe to test.

Use **small synthetic fixtures only**. Do not test destruction against personal data.

### Data persistence

Verify:

- History survives restart.
- Schema updates, if any, behave safely.
- Incomplete scans are represented correctly.
- Trends reflect actual sample intervals.
- Repeated observations do not duplicate or corrupt records.
- Stored history does not grow without bound.
- Own-data deletion/reset behaves as documented.

### RAM subsystem

Verify the meaning and availability of every metric. Test missing permissions, terminated processes, PID reuse, process churn, and sensible handling of false leak indications.

### GUI / end-to-end

Walk through at least:

1. Fresh launch and onboarding.
2. First observation with no prior history.
3. Main dashboard with genuine data.
4. Applications list and footprint details.
5. Biggest folders/projects drill-down.
6. Second observation and real change display.
7. Duplicate candidate search.
8. Read-only cleanup preview.
9. Reveal in Finder.
10. Permission-limited scan.
11. Scan cancellation and error handling.
12. App restart with retained history.
13. RAM monitoring and cautious anomaly language.
14. Dark mode and resizable window.

Do not claim UI verification occurred without opening the actual app or running real UI automation.

### Performance and energy

Benchmark representative realistic workloads without constructing huge artificial datasets.

Observe:

- Startup time.
- Scan duration and progress responsiveness.
- UI frame responsiveness.
- Memory consumption during large scans.
- CPU utilization and disk read load.
- Database/history size growth.
- Repeat-scan efficiency.
- Idle behavior and background energy impact.

Investigate measurements that contradict the product's stated lightweight design.

---

## 25. PRIVACY, SECURITY, AND LOCAL-FIRST DESIGN

The product should be trustworthy enough to consider commercial distribution.

Defaults:

- No mandatory account.
- No required cloud backend.
- No transfer of personal file contents.
- No hidden telemetry.
- No collecting passwords, tokens, private keys, messages, or document contents.
- Read file metadata where sufficient.
- Respect macOS privacy and access boundaries.
- Explain requested permissions and degradations when denied.
- Avoid leaking sensitive absolute paths in public diagnostic reports.
- Store history locally with straightforward retention and deletion controls.
- Keep user selections and exclusions understandable.
- Make full uninstallation documented and realistic.

A privileged helper or more permissive distribution channel must be an explicit design decision, never an undisclosed workaround.

Research and document applicable App Sandbox limits before promising whole-machine inspection in a Mac App Store build.

---

## 26. IMPLEMENTATION STRATEGY AND PRIORITIES

The implementation strategy is yours to optimize, but follow these priority principles:

### Priority A — launchable, truthful foundation

A native `.app` that opens normally, measures genuine disk capacity and scoped filesystem usage, shows scan coverage, and provides a clean, usable first screen.

### Priority B — explain the space

Application footprint, project attribution, category breakdowns, drill-down, real paths, and confidence indicators.

### Priority C — explain changes

Persistent snapshots, growth comparison, time-series views, meaningful anomaly insights, and lean monitoring.

### Priority D — informed action

Duplicate identification, stale-data candidates, cleanup recommendations, and a reliable dry-run safety workflow.

### Priority E — professional finish

RAM view, accessibility, visual polish, performance, diagnostics, comprehensive tests, install/uninstall flow, and App Store readiness analysis.

Build an integrated executable early. Integrate frequently. Do not leave independently developed subsystems until the final hours.

If a complex feature risks delaying the entire product, deliver a rigorous, useful subset with honest limits, then iterate.

No fake capabilities, dummy data, or partially wired interfaces in the installed app.

---

## 27. ACCEPTANCE CRITERIA

Do not mark the complete product mission finished until these claims can be demonstrated:

1. A real native macOS `.app` exists and launches without the terminal.
2. The owner can locate and open it normally.
3. It reports genuine internal SSD capacity/usage with labeled methodology.
4. It identifies meaningful local contributors to usage within granted permissions.
5. Applications and projects have understandable footprint drill-down.
6. Unknown and inaccessible space is distinguished from measured space.
7. Observations persist, and a second observation enables an honest change comparison.
8. Growth signals and history work on actual observations.
9. Duplicate candidates are verified reliably and not blindly considered deletable.
10. Cleanup plans work in dry-run and clearly describe consequences.
11. No real user data was deleted during development.
12. RAM monitoring offers real metrics and appropriately cautious diagnostics.
13. The interface is coherent, responsive, keyboard-friendly, and visually checked.
14. Essential error, permission, cancellation, and no-history states work.
15. Critical filesystem and deletion safety logic has credible tests.
16. The app's idle and scan resource costs have been measured.
17. Its own files and dependencies are traceable and removable.
18. Installation and operation are documented simply.
19. The repository is correctly connected and meaningful work is pushed to `origin/main`.
20. The special 2023 commit-date progression, if used, is transparently documented and did not damage existing history.
21. Agent handoff notes are short, accurate, and ready for continuation.
22. No important recovery material, unrelated project, or security protection was changed.

If any criterion remains unmet by morning, do **not** claim the full mission is complete. Report precisely what works, what remains, and the strongest next step. The objective is genuine progress, not a fictional completion certificate.

---

## 28. WHAT THE OWNER SHOULD FIND IN THE MORNING

The ideal result is a properly installed Disker app that opens with a click and shows real information about the cleaned Mac.

Provide a concise Russian report with:

- App name, exact installation path, and how to launch it.
- What is implemented and demonstrably functional.
- Initial real SSD observations and their coverage.
- How history and growth detection work.
- Current state of duplicate and cleanup features.
- Whether RAM monitoring is available and its caveats.
- What was installed for development, versions, and locations.
- Permissions the user may need to grant later.
- Testing performed and concrete results.
- Resource consumption measurements.
- GitHub remote, branch, and last successfully pushed commit.
- How far the deliberately backdated 2023 commit sequence progressed.
- Actual agent/model and goal-mode capabilities that were used.
- Remaining blockers and App Store distribution limitations.
- Top follow-up priorities and the location of the compact handoff.

Be factual. Distinguish implemented, tested, partially implemented, and planned features. No marketing fluff and no invented screenshots, tests, or performance figures.

If the implementation is incomplete, leave the **best usable, stable build** available and the source safely pushed, then accurately explain what is missing. Never substitute feature-count inflation for a product that works.

---

## 29. START EXECUTING NOW

Do not respond with a lengthy proposal and then stop.

Perform a brief preflight of system state, toolchain, repository, real agent/model options, and goal-mode support. Then create the project, make an early functioning build, delegate useful independent work where supported, run real tests, improve the app, commit meaningful increments with the specified chronological presentation, and push continuously to the designated GitHub repository.

Make professional decisions without asking the owner to choose every screen, color, API, library, or implementation detail.

Keep the machine safe and the execution grounded in reality. When an interactive approval is needed, continue safe independent tasks if possible; otherwise preserve progress and report the exact blocker.

**FINAL GOAL:** Deliver a polished, dependable, intuitive, native macOS storage-intelligence application that makes the owner's SSD and RAM behavior comprehensible, identifies meaningful changes and candidate waste, enables safe cleanup decisions, maintains a clean auditable installation footprint, and can continue evolving under disciplined Sol/Luna orchestration.

**Pursue the goal. Build and test real software. Push meaningful work. Keep history transparent. Never sacrifice safety or product quality for an appearance of progress.**
