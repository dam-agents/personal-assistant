#!/usr/bin/env bash
# The audit must emit a well-formed report, catch a broken task row, and never
# report a check it could not run as a pass.
set -u
. "$(dirname "$0")/lib.sh"
sandbox

write_config
task_header "$WORK/TASKS.md"
task_header "$WORK/TASKS-archive.md"
add_row "$WORK/TASKS.md" T-0001 open - - "$(day -2)T08:00:00Z" "$(day -2)T08:00:00Z" dm "Fine row"
printf '| oops | open | - | - | - | - | dm | Broken row |\n' >> "$WORK/TASKS.md"
echo 1 > "$WORK/TASKS-counter"
printf '{"ts":"%s","run":"r1","job":"brief","level":"error","event":"message_sent","msg":"brief failed: channel 503"}\n' \
  "$(now_iso)" > "$WORK/logs/events-$(day 0).jsonl"

out="$(PA_SKIP_STRUCTURE=1 HOME="$SB" WORK_DIR="$WORK" TZ=UTC bash "$PREFLIGHT" audit 2>/dev/null)"
assert_eq audit "$(printf '%s' "$out" | jq -r '.mode')" "audit emits its mode"
assert_eq false "$(printf '%s' "$out" | jq -r '.nothing_to_do')" "an audit always has work"
assert_eq fail  "$(printf '%s' "$out" | jq -r '.checks[] | select(.id=="tasks_shape") | .status')" "unparseable row fails the shape check"
assert_eq ok    "$(printf '%s' "$out" | jq -r '.checks[] | select(.id=="work_not_git") | .status')" "plain work/ passes"
assert_eq 1     "$(printf '%s' "$out" | jq '.failures | length')" "the week's error events are grouped"

# a missing definition checkout is a failure while definition_repo claims one exists
assert_eq fail "$(printf '%s' "$out" | jq -r '.checks[] | select(.id=="definition_clean") | .status')" "unreadable checkout is not reported clean"

# local-only (definition_repo empty): the same missing checkout is the deployment's shape,
# reported as a warn — never a green, never a failed run (docs/persistence.md)
sed -i.bak 's/^- definition_repo: .*/- definition_repo:/' "$WORK/CONFIG.md" && rm -f "$WORK/CONFIG.md.bak"
out_local="$(PA_SKIP_STRUCTURE=1 HOME="$SB" WORK_DIR="$WORK" TZ=UTC bash "$PREFLIGHT" audit 2>/dev/null)"
assert_eq warn "$(printf '%s' "$out_local" | jq -r '.checks[] | select(.id=="definition_clean") | .status')" "local-only reports the missing checkout as a warn"
sed -i.bak 's|^- definition_repo:.*|- definition_repo: acme/personal-assistant|' "$WORK/CONFIG.md" && rm -f "$WORK/CONFIG.md.bak"

mkdir -p "$WORK/.git"
out2="$(PA_SKIP_STRUCTURE=1 HOME="$SB" WORK_DIR="$WORK" TZ=UTC bash "$PREFLIGHT" audit 2>/dev/null)"
assert_eq fail "$(printf '%s' "$out2" | jq -r '.checks[] | select(.id=="work_not_git") | .status')" "a git dir in work/ is caught"

exit $FAILURES
