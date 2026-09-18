#!/usr/bin/env bash
# The review must count the week honestly and never send twice in one ISO week.
set -u
. "$(dirname "$0")/lib.sh"
sandbox

write_config
task_header "$WORK/TASKS.md"
task_header "$WORK/TASKS-archive.md"
add_row "$WORK/TASKS.md" T-0001 open "$(day -2)" - "$(day -40)T08:00:00Z" "$(day -40)T08:00:00Z" dm "Old and overdue"
add_row "$WORK/TASKS.md" T-0002 open - - "$(day -1)T08:00:00Z" "$(day -1)T08:00:00Z" dm "Fresh undated"
add_row "$WORK/TASKS-archive.md" T-0000 done - - "$(day -20)T08:00:00Z" "$(day -1)T09:00:00Z" dm "Closed this week"
add_row "$WORK/TASKS-archive.md" T-0009 done - - "$(day -60)T08:00:00Z" "$(day -30)T09:00:00Z" dm "Closed long ago"
echo 9 > "$WORK/TASKS-counter"

out="$(run_preflight review)"
assert_eq false "$(printf '%s' "$out" | jq -r '.nothing_to_do')" "review has work"
assert_eq 1 "$(printf '%s' "$out" | jq '.counters.done')"    "only this week's completion counts"
assert_eq 2 "$(printf '%s' "$out" | jq '.counters.open')"    "both live rows are open"
assert_eq 1 "$(printf '%s' "$out" | jq '.counters.overdue')" "one overdue"
assert_eq 1 "$(printf '%s' "$out" | jq '.counters.stale')"   "one untouched past stale_task_days"

printf '%s review week=%s sent=1 done=1\n' "$(now_iso)" "$(TZ=UTC date -u +%G-W%V)" >> "$WORK/REVIEW.log"
out2="$(run_preflight review)"
assert_eq true         "$(printf '%s' "$out2" | jq -r '.nothing_to_do')" "second review this week is suppressed"
assert_eq already_sent "$(printf '%s' "$out2" | jq -r '.reason')"        "dedup reason reported"

exit $FAILURES
