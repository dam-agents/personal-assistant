# Logging

Read this file when you write a log line by hand, when you add one to a script, or when you
diagnose a failure in the weekly audit.

**The owner's content never enters a log.** IDs, counts, intents, and error shapes only —
no task titles, no note text, no message bodies, no fragments of what the owner wrote
(`CLAUDE.md` → **Hard invariants**). This is the one rule that outranks diagnosability
here: an assistant's logs would otherwise become a copy of someone's private list.

## Two layers

### Per-run summary logs — `work/<RUNTYPE>.log`

Append-only, one line per run, UTC first. Shapes (each defined once, here):

```
<ISO-UTC> brief  day=<YYYY-MM-DD> sent=1 overdue=<n> due=<n> upcoming=<n> waking=<n>
<ISO-UTC> brief  day=<YYYY-MM-DD> sent=0 reason=<slug>
<ISO-UTC> review week=<YYYY-Www> sent=1 done=<n> dropped=<n> open=<n> overdue=<n> stale=<n>
<ISO-UTC> review week=<YYYY-Www> sent=0 reason=<slug>
<ISO-UTC> audit  ok=<n> warn=<n> red=<n> sent=<channel|chat>
```

- `day=` and `week=` are **owner-local** (the timestamp is UTC, the day is not) — they are
  what the pre-flight greps to decide the brief or review already went out.
- `sent=1` is written by the agent **immediately after** a successful send. The pre-flight
  writes only `sent=0` lines, for the runs it ended itself.
- `reason` is a slug, never a sentence: `gated`, `nothing_due`, `already_sent`,
  `send_failed`, `no_member_id`.
- A run that fails outright writes `ERROR: <short cause>` — the audit's weekly error scan is
  one grep for that prefix. `AUDIT.log` deliberately avoids the word so the scan never reads
  its own findings back as failures.

### Structured events — `work/logs/events-YYYY-MM-DD.jsonl`

Written through `scripts/log.sh` (`logev <level> <event> <msg>`), one JSON object per line:
`{ts, run, job, level, event, msg}`. `run` groups a session, `job` is the run type.
`debug` lines appear only when `log_level: debug` ([config.md](config.md)).

Event catalogue — `event` is a fixed slug, `msg` follows the grammar given here, so a
hand-written line (when `log.sh` is unavailable) matches what the audit groups:

| `event` | Written by | `msg` grammar |
| --- | --- | --- |
| `preflight` | `preflight.sh` | `<mode> <decision>` — e.g. `brief nothing_to_do`, `review 7 entries` |
| `message_sent` | agent | `<runtype> ok` / `<runtype> failed: <short cause>` |
| `task_write` | agent | `<op> <id>` — `add`, `complete`, `drop`, `snooze`, `edit`, `note` |
| `config_change` | agent | `<key> <old> -> <new>` (values only) |
| `persona_change` | agent | `<file> <section>` — never the text |
| `inbox` | agent | `<intent> <action>` |
| `memory` | agent (review) | `merged <n> promoted <n> dropped <n>` |
| `work_backup` | `work-backup.sh` | its own messages |
| `onboarding_verify` | `verify-onboarding.sh` | `PASS <scope> …` / `FAILED <scope> …` |
| `audit` | agent | `ok=<n> warn=<n> red=<n>` |

`level: error` is reserved for a failure that changed nothing or lost something; a declined
request is `info`.

### `work/INBOX.log` — the inbound ledger

One line per handled message, written immediately after the reply
([conversation.md](conversation.md)):

```
<ISO-UTC> msg=<message-id> intent=<intent> action=<slug> tasks=<ids|->
```

`action` is one of `answered`, `written`, `declined`, `failed`. It is what keeps a
re-delivered message from being answered twice; the audit trims it to the last 90 days.

## Diagnosing a failure

The audit's pre-flight groups the week's `level: error` events into signatures
(`event`/`msg` with volatile parts normalized, first and last seen). For each one, name the
cause and classify it ([audit.md](audit.md)): **environment** (record it in
`work/LESSONS.md` once the cause is verified — pod facts are lost on restart), **agent
mistake** (a run did the wrong thing — say so in the report), or **definition bug** (open a
deduplicated tracking issue on `definition_repo`). Counting errors without asking why is not
a diagnosis.

## Tool path resolution

`scripts/lib/toolpath.sh` shadows `jq` and `gh` with their real binaries for the life of a
shell process. On the platform pod both resolve to `mise` shims, and every exec re-resolves
the toolchain (~250 ms against ~17 ms for the binary); the pre-flight execs `jq` dozens of
times per run. Sourcing it costs one `mise bin-paths` call on a cold cache and nothing
afterwards.

It is a workaround, not the fix: the shim belongs to the pod image
([self-modification.md](self-modification.md) §5a). It never modifies `PATH` (the offline
tests stub CLIs by prepending to it), never fails a run, and leaves an already-real binary
alone. The audit's `tool_shims` check keeps reporting the shimmed names — reading what was
seen *before* shadowing — until the image is fixed.
