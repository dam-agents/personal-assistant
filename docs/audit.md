# Weekly audit

Read this file for an `audit` run. Nobody watches this agent day to day, so once a week it
watches itself: a dead schedule, a drifted state file, a config key the runtime cannot see,
an expired connection — each of them is silent until someone notices work not happening.

The audit is **read-only toward the outside and repair-free**. It reports; routine problems
heal on the next run of their own pipeline, everything else goes to the owner. Its only
writes are its log line, the retention sweeps the pre-flight performs, and the memory
consolidation — which belongs to the review, not here.

A skipped check is an incomplete audit: a check that could not run is reported `warn` with
the reason, never dropped and never turned into a green. A measurement whose scan failed
says "not measured" — a fabricated clean number is worse than a missing one.

## Deterministic — `scripts/preflight.sh audit`

Emitted as `checks[] = {id, status: ok|warn|fail, detail}`, plus `failures[]` and `stats`.
Do not recompute them by hand; read them.

| Check | Fails when |
| --- | --- |
| `structure` | `scripts/verify-onboarding.sh` (offline) reports a FAIL — a state file or a config key drifted out of shape. This is where config validity is measured. |
| `work_not_git` | `work/.git` exists — the invariant the shared volume forces ([persistence.md](persistence.md)). |
| `nfs_junk` | `.nfs*` files under `work/` — an early concurrency signal. |
| `tasks_shape` | A row does not parse, an ID repeats, or a `done`/`dropped` row sits in the live file. |
| `tasks_counter` | The counter is missing or below the highest allocated ID — IDs could be reused. |
| `tasks_orphans` | A `work/TASKS/<id>.md` note has no row in either the live file or the archive. |
| `cadence_brief`, `cadence_review`, `cadence_audit` | An enabled run type has not logged a run within its expected window. |
| `errors` | `ERROR:` lines in `work/*.log`. No log file at all is `warn` — not measured, never a green. |
| `retention` | Housekeeping report: events files older than 14 days and `INBOX.log` lines older than 90 days removed. |
| `memory_bounds` | `## Observed` over its cap ([preferences.md](preferences.md)). |
| `disk` | `work/` is over the warn threshold, or usage could not be measured. |
| `definition_clean` | `git -C $HOME status --porcelain` is not empty, or there is no checkout to read. |
| `version` | Checked out, latest, and adopted versions disagree. Drift is reported, never fixed here. |
| `tool_shims` | A CLI still reaches through a `mise` shim ([logging.md](logging.md) → **Tool path resolution**). |
| `tmp` | Leftover `/tmp/personal-assistant-*` directories. |

`failures[]` groups the week's `level: error` events into signatures; `stats` carries the
week in numbers: runs and sends per proactive type, idle runs, inbound messages handled and
declined. Task counters come from the review's worklist, not from here.

## Judgment — yours

1. **Schedules exist and are enabled** — `mcp__platform-outbound__list_schedules`: every run
   type the configuration enables has its `personal-assistant-*` schedule with the cron
   `ONBOARDING.md` Step 4 registered. A dead schedule is invisible to every other check: the
   cadence check catches the past, this one catches the future. A schedule for a disabled
   run type is a `warn`, not a fix.
2. **Diagnose every `failures[]` signature** — cause and fix, classified as environment,
   agent mistake, or definition bug ([logging.md](logging.md) → **Diagnosing a failure**).
   A verified environment cause goes to `work/LESSONS.md`; a definition bug becomes a
   deduplicated tracking issue on `definition_repo` (search open issues first) — the audit's
   only external write.
3. **Sample this week's messages** (about three, from the logs and the state they describe):
   did they go only to `owner_member_id`, did they honor `work/PERSONA.md`'s boundaries, did
   a declined request stay declined, is every task mentioned still in the state it claimed?
4. **The double-send window** — two `sent=1` brief lines inside one owner-local day, or two
   review lines in one ISO week. That is the crash window between the send and the log
   append; one occurrence is expected behavior of send-then-record, a pattern is a bug.
5. **Ledger integrity** — an inbound message ID appearing twice in `work/INBOX.log` with
   `action=answered` means a message was answered twice.
6. **Trends** — backlog age, the stale list growing week over week, the share of requests
   declined because a duty is disabled (a persistent one is worth telling the owner about),
   idle-run ratio.
7. **Config validity in practice** — `owner_member_id` still resolves on the channel;
   `timezone` is a name the pod's `date` accepts; proactive keys agree with the schedules
   that exist.

## The report

One message, traffic-light, counts and one-liners over prose:

```
🩺 *<display name> weekly audit* — <date> · 🟢 N ok · 🟡 N warn · 🔴 N fail

*Week in numbers* (since <ISO>)
• tasks: +<added> / <done> done / <dropped> dropped · open <n> (overdue <n>, stale <n>)
• messages: <sent> sent · <handled> handled · <declined> declined · idle runs <n>/<n>

*Checks*
🔴 <id> — <detail>
🟡 <id> — <detail>
🟢 all other checks passed (<count>)

*Action needed*: <one line per item needing the owner, or "none">
```

Delivery: the chat UI always; the owner's channel too when `audit_report: enabled` and
`channel_notifications: enabled` — a failed send is itself a finding. Then append the
`AUDIT.log` line ([logging.md](logging.md)) and persist `work/`.

## Self-check before ending the run

- Every `checks[]` entry appears in the report; no fail was summarized away.
- Every `failures[]` signature got a cause and a classification.
- Nothing was repaired, no task was touched, nothing external was written except an allowed
  tracking issue.
- The log line is written and `AUDIT.log` still contains no `ERROR:` substring.
