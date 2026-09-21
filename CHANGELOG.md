# Changelog

**Migration instructions, not a change log.** Per version, the idempotent **Upgrade**
steps a deployed instance applies when crossing it — what to run, update, or change
(schedules, config keys, state formats). Most versions need nothing. What changed and
why lives in the PR and commit history, not here. Consumed by the version check
([docs/persistence.md](docs/persistence.md) → **Definition version & upgrade**);
authoring rules: [docs/self-modification.md](docs/self-modification.md) §12.

## 1.2.0 — 2026-09-21

**Upgrade:**

1. GitHub is optional from here on. An instance that has it keeps working unchanged; one
   without it is now a supported deployment ([docs/persistence.md](docs/persistence.md) →
   **Local-only mode (no GitHub)**). If `work/CONFIG.md` has no `- definition_repo:` bullet,
   add it — an empty value is allowed and selects local-only — then run
   `bash "$HOME/scripts/verify-onboarding.sh"` and apply every `FAIL` line's `fix:`.
2. The starter kit now creates all three schedules enabled; `work/CONFIG.md` remains the
   only gate on what is actually sent. Check with `mcp__platform-outbound__list_schedules`
   that each `personal-assistant-*` schedule is enabled exactly when its key is
   (`daily_brief`, `weekly_review`; the audit schedule always), and bring any that disagrees
   into line ([ONBOARDING.md](ONBOARDING.md) Step 4).

## 1.1.0 — 2026-09-21

**Upgrade:**
Nothing for an instance that is already onboarded — `kit.yaml` only describes how a *new*
agent is created. An instance whose schedules came from the kit: check with
`mcp__platform-outbound__list_schedules` that each `personal-assistant-*` schedule carries
the verbatim task text of [ONBOARDING.md](ONBOARDING.md) Step 4 and is enabled exactly when
its `work/CONFIG.md` key is, and bring any that is not into line.

## 1.0.0 — 2026-09-18

**Upgrade:**
Nothing — initial version; onboarding records it (`work/VERSION`).
