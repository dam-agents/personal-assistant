# Weekly review

Read this file for a `review` run — the Monday look back and look ahead.

Gates (checked by `scripts/preflight.sh review`): `duty_briefing`, `weekly_review`,
`channel_notifications` all `enabled`, `owner_member_id` set, and no `sent=1` review line
for the current ISO week in `work/REVIEW.log`.

## Worklist

| Key | Entries |
| --- | --- |
| `done_week` | Archive rows with `updated` inside the last 7 days (`status: done`). |
| `dropped_week` | The same window, `status: dropped`. |
| `open` | Live `open` rows, due-date order then age. |
| `overdue` | Live `open` rows past their due date. |
| `stale` | Live `open` rows untouched for more than `stale_task_days`. |
| `counters` | `{done, dropped, added, open, overdue, stale, snoozed}` for the week. |

## The message

One message, in the persona's voice, in this order:

1. **Closed last week** — the count, then the titles. This is the part the owner reads
   first; do not compress it into a number.
2. **Still open** — grouped as overdue / this week / later / undated.
3. **Stale** — each with its age and one question: still wanted, or drop it? Ask; never drop
   anything yourself.
4. **One observation** — at most one, and only when the state supports it: a recurring theme
   in what gets dropped, a backlog that grew every week this month, a duty the owner keeps
   asking for that no module covers ([duties.md](duties.md)). No observation is better than
   an invented one.

Never grade the owner, never compare them to a previous week's "performance", and never
suggest a system change they did not ask about.

## After sending

1. Immediately after the send, append the `sent=1` review line to `work/REVIEW.log` in the
   shape of [logging.md](logging.md) → **Per-run summary logs**, with `week=` in the owner's
   local ISO week. A failed send appends `sent=0 reason=send_failed`, is reported in the chat
   UI, and is retried by next week's run.
2. **Memory pass** — the one learning step of the week: apply
   [preferences.md](preferences.md) → **Weekly consolidation** to `work/MEMORY.md`. Report
   the delta as one line in the chat UI, not in the owner's message.
3. **Persist** `work/`.

## Self-check before ending the run

- Every open task appears exactly once, in exactly one group.
- Counts in the message equal the worklist's `counters` — no number was recomputed by hand,
  and none was guessed when a scan failed (say "not measured" instead).
- Exactly one message, to `owner_member_id`, and the log line matches it.
- Nothing was completed, dropped, or edited by this run — the review reports, the owner
  decides.
