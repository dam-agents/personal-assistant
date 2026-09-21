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
add_row "$WORK/TASKS.md" T-0002 open - - "$(day -2)T08:00:00Z" "$(day -2)T08:00:00Z" dm "Quarterly summary draft"
printf '| oops | open | - | - | - | - | dm | Broken row |\n' >> "$WORK/TASKS.md"
echo 2 > "$WORK/TASKS-counter"
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

# --- the two privacy checks (docs/privacy.md), green on clean state ...
assert_eq ok "$(printf '%s' "$out" | jq -r '.checks[] | select(.id=="secret_scan") | .status')" "clean work/ carries no credential"
assert_eq ok "$(printf '%s' "$out" | jq -r '.checks[] | select(.id=="log_hygiene") | .status')" "clean logs carry no task title"

# ... and failing once a credential lands in a note and a title lands in a log.
# The token is assembled at runtime so this file holds no scanner-matchable literal.
printf 'ghp_%036d\n' 0 > "$WORK/TASKS/T-0002.md"
printf '%s brief day=%s sent=1 Quarterly summary draft\n' "$(now_iso)" "$(day 0)" > "$WORK/BRIEF.log"
out_priv="$(PA_SKIP_STRUCTURE=1 HOME="$SB" WORK_DIR="$WORK" TZ=UTC bash "$PREFLIGHT" audit 2>/dev/null)"
assert_eq fail "$(printf '%s' "$out_priv" | jq -r '.checks[] | select(.id=="secret_scan") | .status')" "a credential under work/ fails the audit"
assert_contains "TASKS/T-0002.md" "$(printf '%s' "$out_priv" | jq -r '.checks[] | select(.id=="secret_scan") | .detail')" "secret_scan names the file"
assert_eq 0 "$(printf '%s' "$out_priv" | jq -r '.checks[] | select(.id=="secret_scan") | .detail' | grep -c 'ghp_')" "secret_scan never carries the match"
assert_eq fail "$(printf '%s' "$out_priv" | jq -r '.checks[] | select(.id=="log_hygiene") | .status')" "a task title in a log fails the audit"
assert_contains "T-0002" "$(printf '%s' "$out_priv" | jq -r '.checks[] | select(.id=="log_hygiene") | .detail')" "log_hygiene names the id"
assert_eq 0 "$(printf '%s' "$out_priv" | jq -r '.checks[] | select(.id=="log_hygiene") | .detail' | grep -c 'Quarterly')" "log_hygiene never carries the title"
rm -f "$WORK/TASKS/T-0002.md" "$WORK/BRIEF.log"

mkdir -p "$WORK/.git"
out2="$(PA_SKIP_STRUCTURE=1 HOME="$SB" WORK_DIR="$WORK" TZ=UTC bash "$PREFLIGHT" audit 2>/dev/null)"
assert_eq fail "$(printf '%s' "$out2" | jq -r '.checks[] | select(.id=="work_not_git") | .status')" "a git dir in work/ is caught"

exit $FAILURES
