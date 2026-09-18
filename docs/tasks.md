# Tasks — the list and its lifecycle

Read this file for any read or write of the task list. It is the single home of the task
row format; the pre-flight, the verification script, the brief, and the review all parse
what is defined here.

Requires `duty_tasks: enabled` ([config.md](config.md)) — otherwise decline per
[duties.md](duties.md).

## Files

| File | Holds |
| --- | --- |
| `work/TASKS.md` | Live tasks — **only** `open` and `snoozed` rows. |
| `work/TASKS-archive.md` | Append-only: every task that reached `done` or `dropped`. |
| `work/TASKS/<id>.md` | Optional per-task notes, created on first note. |
| `work/TASKS-counter` | One integer: the highest ID number ever allocated. |

## Row format

Both files carry one table with this exact header (the verification script checks it
literally):

```markdown
| id | status | due | snoozed_until | created | updated | source | title |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T-0001 | open | 2026-09-22 | - | 2026-09-18T07:11:02Z | 2026-09-18T07:11:02Z | dm | Draft the quarterly summary |
```

- **`id`** — `<task_prefix>-<4+ digits>`, zero-padded, allocated from `work/TASKS-counter`:
  the next ID is `max(counter, highest ID in both files) + 1`, written back to the counter
  **before** the row is written. IDs are never reused, never renumbered.
- **`status`** — `open` | `snoozed` in `TASKS.md`; `done` | `dropped` in the archive. No
  other value exists, and `done`/`dropped` never stay in the live file.
- **`due`** — `YYYY-MM-DD` in the owner's `timezone`, or `-`. A date the owner stated; not a
  write timestamp.
- **`snoozed_until`** — `YYYY-MM-DD` when `status: snoozed`, else `-`. The pre-flight wakes
  the row on the first run on or after this date.
- **`created`**, **`updated`** — real UTC write times, `YYYY-MM-DDTHH:MM:SSZ`. `updated`
  changes on every row edit; in the archive it is the completion/drop time.
- **`source`** — `dm` | `chat` | `brief` | `review`, where the task entered the list.
- **`title`** — one line, the owner's wording, trimmed. **Replace every `|` with `/` and
  every newline with a space** — a raw pipe breaks the table for every reader. Anything
  longer than a line goes into the note file, not the title.

## Operations

Each one is a complete unit: do the write, then confirm. A task write requested in a
conversation is **write-before-send** — the row lands first, the confirmation second; an
unconfirmed task the owner repeats is a duplicate they can see, a confirmed task that was
never written is one they will count on.

- **Add** — allocate the ID, append the row (`status: open`, `created` = `updated` = now).
  A due date only when the owner gave one; never invent one. Ambiguous wording is captured
  verbatim as the title and clarified in the reply, not silently interpreted.
- **Complete / drop** — append the row to `work/TASKS-archive.md` with `status: done` (or
  `dropped`) and `updated` = now, **then** remove it from `work/TASKS.md`. In that order: a
  row in both files is a visible duplicate the audit catches, a row in neither is lost work.
  The note file stays where it is.
- **Snooze** — `status: snoozed`, `snoozed_until` = the date, `updated` = now. The
  pre-flight flips it back to `open` on or after that date (its one documented status flip)
  and reports it as `waking` so the brief can mention it.
- **Edit** — change the field, set `updated` = now. Changing a title keeps the ID.
- **Note** — append to `work/TASKS/<id>.md` under a `## <UTC timestamp>` heading. Notes hold
  whatever the owner wants kept with the task; they are never summarized into the title and
  never copied into a log.
- **List** — read the live file, group per [brief.md](brief.md)'s ordering (overdue, due
  today, upcoming, undated, snoozed). Never list the archive unless asked for history.

## Safety rules

- Verify per item before removing anything: a task leaves the live file only after its
  archive line is written, and a note file is deleted only when the owner asks for that
  specific task's notes to go. **Never bulk-delete rows or note files**, and never rewrite
  the whole file to "clean it up" — repair the one row that is broken.
- A row that does not parse is left in place, reported to the owner, and flagged by the
  audit. Guessing at a broken row's meaning loses the owner's data quietly.
- Task content is the owner's: it goes to their channel and their notes, never into
  `work/logs/` (`CLAUDE.md` → **Hard invariants**). Log the ID and the action, nothing else.
