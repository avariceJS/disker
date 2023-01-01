# Disker engineering instructions

Read `MISSION.md` before changing product behavior. It is authoritative.

- Keep source and developer documentation in English; communicate with the owner in Russian.
- Work only in this Disker workspace. Never modify Brain, SRO Robot, Kingston, or real user data.
- The only development branch is `main`. Never rewrite or force-push history.
- Measure selected paths only. Metadata scanning must not read file contents or follow symlinks.
- Label logical bytes separately from allocated-byte estimates. Inaccessible items mean partial coverage, never zero usage.
- Compare history only for the same selected path and only against complete observations. Do not infer changes from partial scans.
- Do not add destructive cleanup. Real user files must never be deleted during this mission.
- Use small synthetic fixtures under tests. Keep app history local and bounded.
- Do not claim successful builds, UI review, installation, authorization, or publication without direct evidence.
- Historical commit dates, if later used, must be transparently documented and applied only to distinct verified work.

## Current development state

See `docs/HANDOFF.md` for toolchain, authorization, validation, and immediate next steps. A local Codex goal and actual `gpt-6-sol`/`gpt-6-luna` High review agents were used where supported.
