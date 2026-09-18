#!/usr/bin/env bash
# The brief must see exactly what is due, wake an expired snooze exactly once,
# and stay silent when a gate is off.
set -u
. "$(dirname "$0")/lib.sh"
sandbox

write_config
task_header "$WORK/TASKS.md"
task_header "$WORK/TASKS-archive.md"
add_row "$WORK/TASKS.md" T-0001 open "$(day -3)" - "$(day -30)T08:00:00Z" "$(day -30)T08:00:00Z" dm "Overdue one"
add_row "$WORK/TASKS.md" T-0002 open "$(day 0)"  - "$(day -2)T08:00:00Z"  "$(day -2)T08:00:00Z"  dm "Due today"
add_row "$WORK/TASKS.md" T-0003 open "$(day 1)"  - "$(day -2)T08:00:00Z"  "$(day -2)T08:00:00Z"  dm "Tomorrow"
add_row "$WORK/TASKS.md" T-0004 open "$(day 9)"  - "$(day -2)T08:00:00Z"  "$(day -2)T08:00:00Z"  dm "Far away"
add_row "$WORK/TASKS.md" T-0005 snoozed - "$(day -1)" "$(day -9)T08:00:00Z" "$(day -9)T08:00:00Z" dm "Snooze expired"
echo 5 > "$WORK/TASKS-counter"

out="$(run_preflight brief)"
assert_eq false "$(printf '%s' "$out" | jq -r '.nothing_to_do')" "brief has work"
assert_eq 1 "$(printf '%s' "$out" | jq '.overdue | length')"   "one overdue"
assert_eq 1 "$(printf '%s' "$out" | jq '.due_today | length')" "one due today"
assert_eq 1 "$(printf '%s' "$out" | jq '.upcoming | length')"  "one upcoming inside the lead window"
assert_eq 1 "$(printf '%s' "$out" | jq '.waking | length')"    "one snooze woken"
assert_eq 3 "$(printf '%s' "$out" | jq -r '.overdue[0].overdue_days')" "overdue age computed"

# the wake is a state change, so the second run must not report it again
assert_eq 1 "$(grep -c '^| T-0005 | open |' "$WORK/TASKS.md")" "woken row rewritten as open"
out2="$(run_preflight brief)"
assert_eq 0 "$(printf '%s' "$out2" | jq '.waking | length')" "waking is one-shot"

# a gate off means a quiet run, not a message
sed -i.bak 's/- daily_brief: enabled/- daily_brief: disabled/' "$WORK/CONFIG.md"
out3="$(run_preflight brief)"
assert_eq true   "$(printf '%s' "$out3" | jq -r '.nothing_to_do')" "gated run is quiet"
assert_eq gated  "$(printf '%s' "$out3" | jq -r '.reason')"        "gate reason reported"

exit $FAILURES
