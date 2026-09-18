# Morning brief

Read this file for a `brief` run. The pre-flight has already decided there is something to
say; this file is what you say and in what order.

Gates (all checked by `scripts/preflight.sh brief`, re-check nothing yourself unless the
worklist is missing): `duty_briefing`, `daily_brief`, `channel_notifications` all `enabled`,
`owner_member_id` set, and no `sent=1` brief line for today in `work/BRIEF.log`.

## Worklist

| Key | Entries |
| --- | --- |
| `waking` | Tasks whose snooze expired; the pre-flight already flipped them to `open`. |
| `overdue` | `open` tasks with `due` before today. |
| `due_today` | `open` tasks with `due` = today. |
| `upcoming` | `open` tasks due within `reminder_lead_days`. |

Each entry: `{id, title, due, snoozed_until, age_days}`.

## The message

One message, in the persona's voice and language, in this order — skip any empty group
rather than writing "none":

1. **Overdue** — oldest first, with how long they have been due.
2. **Due today**.
3. **Back from snooze** — one line, named.
4. **Coming up** — inside `reminder_lead_days`.
5. **One closing line** when the persona's voice wants one. No pep talk unless the owner
   asked for one in `work/PERSONA.md`.

Rules:

- Tasks are listed as `<id> <title>` so a reply can name one. Never renumber or re-title.
- No counts the pre-flight did not measure, no progress claims, no invented priorities.
  Order is due date, then age — priority is the owner's to state, not yours to infer.
- Keep it scannable: one task per line, no nested structure, no tables.

## After sending

1. **Send first, record second** — the brief is a message ([conversation.md](conversation.md)
   applies the same ordering rule). Immediately after the send succeeds, append the `sent=1`
   brief line to `work/BRIEF.log` in the shape of [logging.md](logging.md) → **Per-run summary
   logs**, with `day=` in the owner's local date. A failed send appends `sent=0
   reason=send_failed` instead, is reported in the chat UI, and is retried by tomorrow's run —
   never re-sent inside the same run.
2. **Persist** `work/` (`CLAUDE.md` → **Run procedures**).

The `sent=1` line is what stops a second brief today; the audit checks for two of them in
one local day — the crash window between the send and the append
([audit.md](audit.md)).

## Self-check before ending the run

- Every worklist entry appears in the message, or its absence is deliberate and stated.
- Exactly one message was sent, to `owner_member_id`.
- The log line is written and matches what was sent.
- No task content reached `work/logs/`.
