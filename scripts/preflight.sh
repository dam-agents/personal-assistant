#!/usr/bin/env bash
# preflight.sh — deterministic pre-flight for personal-assistant.
#
# The script DETECTS, it NEVER ACTS:
#
#   - NO messages, NO external writes (read-only toward everything outside),
#   - NO git commit/push (the agent persists at end of run),
#   - local writes only: the documented snooze->open flip, the audit's retention
#     sweeps, its own log line, caches.
#
#   preflight.sh <mode>   -> one JSON object on stdout; everything else to stderr.
#   .nothing_to_do == true  -> the agent ends the run immediately.
#   otherwise               -> the agent processes the arrays per CLAUDE.md + docs/.
#
# Modes: brief | review | audit.  Contracts: docs/brief.md, docs/review.md,
# docs/audit.md.  State formats: docs/tasks.md, docs/logging.md.
#
# The owner's content never leaves work/: task titles travel in the worklist (the
# agent needs them to write the message) but never into any log line here.
#
# Requires: bash, jq, git, sed/grep/cut/tr, GNU date (Linux pod). Deliberately
# awk-free — awk is not available in the pod.

set -u
export LC_ALL=C

MODE="${1:-brief}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
TASKS="$WORK/TASKS.md"
ARCHIVE="$WORK/TASKS-archive.md"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

LOGS=()
log() { LOGS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# jq is a mise shim on the pod and this script execs it per task row; resolve it
# once per process (docs/logging.md -> Tool path resolution). Never fatal.
. "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null || true

# The config readers (`cfg`, `cfg_table`) live in one file that every reader of
# CONFIG.md sources — never copied here, so the runtime and the verifier cannot
# drift apart. A missing lib is fatal: parsing config by hand is how they drift.
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }

LOG_JOB="$MODE"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

# Scratch, cleaned up on every exit path — a leftover temp file is an audit finding.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/personal-assistant-preflight.XXXXXX")" || SCRATCH=""
cleanup() { [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"; }
trap cleanup EXIT
BAD_FILE="$SCRATCH/bad-rows"

trim() { local v="${1-}"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
num()  { case "${1-}" in (''|*[!0-9]*) printf 0;; (*) printf '%s' "$1";; esac; }

# ---------------------------------------------------------------- config ----
# Env var of the same name in upper case wins over the stored value; then the
# documented default (docs/config.md).
cfgv() { # <key> <default>
  local k="$1" d="${2-}" envk v
  envk="$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')"
  v="${!envk:-}"
  [ -n "$v" ] || v="$(cfg "$k")"
  [ -n "$v" ] || v="$d"
  printf '%s' "$v"
}

TZ_NAME="$(cfgv timezone UTC)"
OWNER_ID="$(cfgv owner_member_id '')"
OWNER_CHANNEL="$(cfgv owner_channel slack)"
DISPLAY_NAME="$(cfgv display_name Assistant)"
DM_CONTROL="$(cfgv dm_control tasks)"
NOTIFY="$(cfgv channel_notifications disabled)"
DUTY_TASKS="$(cfgv duty_tasks disabled)"
DUTY_BRIEFING="$(cfgv duty_briefing disabled)"
DUTY_ANSWERS="$(cfgv duty_answers disabled)"
DUTY_DRAFTING="$(cfgv duty_drafting disabled)"
DAILY_BRIEF="$(cfgv daily_brief disabled)"
WEEKLY_REVIEW="$(cfgv weekly_review disabled)"
AUDIT_REPORT="$(cfgv audit_report enabled)"
WEB_RESEARCH="$(cfgv web_research enabled)"
TASK_PREFIX="$(cfgv task_prefix T)"
LEAD_DAYS="$(num "$(cfgv reminder_lead_days 1)")"
STALE_DAYS="$(num "$(cfgv stale_task_days 14)")"
DEFINITION_REPO="$(cfgv definition_repo '')"
[ "$LEAD_DAYS" -gt 0 ] 2>/dev/null || LEAD_DAYS=1
[ "$STALE_DAYS" -gt 0 ] 2>/dev/null || STALE_DAYS=14

TODAY="$(TZ="$TZ_NAME" date +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
ISOWEEK="$(TZ="$TZ_NAME" date +%G-W%V 2>/dev/null || date -u +%G-W%V)"

# GNU date first, BSD fallback (macOS during development); 0 on unparsable input.
d2epoch() { date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%d' "$1" +%s 2>/dev/null || echo 0; }
day_plus() { # signed day offset in the owner's timezone
  local n="$1"; case "$n" in ([!+-]*) n="+$n";; esac
  TZ="$TZ_NAME" date -d "$n days" +%Y-%m-%d 2>/dev/null \
    || date -v"${n}d" +%Y-%m-%d 2>/dev/null || printf '%s' "$TODAY"
}
days_since() { # <YYYY-MM-DD> -> whole days until today, 0 when unparsable
  local a b; a="$(d2epoch "$1")"; b="$(d2epoch "$TODAY")"
  { [ "$a" -gt 0 ] && [ "$b" -gt 0 ]; } 2>/dev/null || { echo 0; return; }
  echo $(( (b - a) / 86400 ))
}

CONFIG_JSON="$(jq -n \
  --arg tz "$TZ_NAME" --arg owner "$OWNER_ID" --arg channel "$OWNER_CHANNEL" \
  --arg display "$DISPLAY_NAME" --arg dm "$DM_CONTROL" --arg notify "$NOTIFY" \
  --arg dt "$DUTY_TASKS" --arg db "$DUTY_BRIEFING" --arg da "$DUTY_ANSWERS" \
  --arg dd "$DUTY_DRAFTING" --arg brief "$DAILY_BRIEF" --arg review "$WEEKLY_REVIEW" \
  --arg audit "$AUDIT_REPORT" --arg web "$WEB_RESEARCH" --arg prefix "$TASK_PREFIX" \
  --arg repo "$DEFINITION_REPO" --argjson lead "$LEAD_DAYS" --argjson stale "$STALE_DAYS" \
  --arg today "$TODAY" --arg week "$ISOWEEK" \
  '{timezone:$tz, today:$today, iso_week:$week, owner_member_id:$owner,
    owner_channel:$channel, display_name:$display, dm_control:$dm,
    channel_notifications:$notify, duty_tasks:$dt, duty_briefing:$db,
    duty_answers:$da, duty_drafting:$dd, daily_brief:$brief, weekly_review:$review,
    audit_report:$audit, web_research:$web, task_prefix:$prefix,
    reminder_lead_days:$lead, stale_task_days:$stale, definition_repo:$repo}')"

logs_json() { printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]'; }

quiet_out() { # <reason-slug> <log line>  -> nothing-to-do JSON
  log "$2"
  jq -n --arg mode "$MODE" --arg reason "$1" --argjson cfg "$CONFIG_JSON" \
     --argjson logs "$(logs_json)" \
     '{mode:$mode, nothing_to_do:true, reason:$reason, config:$cfg, logs:$logs}'
  logev info preflight "$MODE nothing_to_do ($1)"
  exit 0
}

fail_out() { # <error>  -> nothing-to-do JSON with an error; the agent just logs it
  jq -n --arg mode "$MODE" --arg err "$1" --argjson cfg "$CONFIG_JSON" \
     --argjson logs "$(logs_json)" \
     '{mode:$mode, nothing_to_do:true, error:$err, config:$cfg, logs:$logs}'
  logev error preflight "$MODE error: $1"
  exit 0
}

# ------------------------------------------------------------- task rows ----
# One compact JSON object per parseable row on stdout. A row that does not parse
# is counted in $BAD_FILE and left alone — never guessed at (docs/tasks.md ->
# Safety rules). The count goes to a file because callers read this through a
# pipe, and a subshell's variable never reaches the caller.
read_tasks() { # <file>
  local file="$1" id status due snoozed created updated source title rest
  [ -f "$file" ] || return 0
  while IFS='|' read -r rest id status due snoozed created updated source title rest; do
    id="$(trim "${id-}")"
    case "$id" in
      ('') continue;;                       # blank or non-table line
      (id|:*|---*) continue;;               # table header / separator
    esac
    case "$id" in
      ("$TASK_PREFIX"-[0-9][0-9][0-9][0-9]*) ;;
      (*) printf 'x\n' >> "$BAD_FILE"; continue;;
    esac
    jq -cn --arg id "$id" --arg status "$(trim "${status-}")" --arg due "$(trim "${due-}")" \
       --arg snoozed "$(trim "${snoozed-}")" --arg created "$(trim "${created-}")" \
       --arg updated "$(trim "${updated-}")" --arg source "$(trim "${source-}")" \
       --arg title "$(trim "${title-}")" \
       '{id:$id, status:$status, due:$due, snoozed_until:$snoozed, created:$created,
         updated:$updated, source:$source, title:$title}'
  done < "$file"
}
bad_rows() { num "$(grep -c . "$BAD_FILE" 2>/dev/null)"; }

# The one documented status flip: a snooze whose date arrived becomes `open`
# again, so the transition is logged once instead of on every later run. Atomic
# tmp + mv — the shared volume corrupts in-place rewrites under concurrent runs
# (docs/persistence.md). Only matched rows change; every other line is copied.
wake_snoozed() { # ids on stdin, one per line
  local ids tmp line id status due created source title
  ids="$(cat)"; [ -n "$ids" ] || return 0
  tmp="$SCRATCH/tasks.new"
  while IFS= read -r line; do
    case "$line" in
      ('|'*)
        id="$(trim "$(printf '%s' "$line" | cut -d'|' -f2)")"
        status="$(trim "$(printf '%s' "$line" | cut -d'|' -f3)")"
        if [ "$status" = snoozed ] && printf '%s\n' "$ids" | grep -qxF "$id"; then
          due="$(trim "$(printf '%s' "$line" | cut -d'|' -f4)")"
          created="$(trim "$(printf '%s' "$line" | cut -d'|' -f6)")"
          source="$(trim "$(printf '%s' "$line" | cut -d'|' -f8)")"
          title="$(trim "$(printf '%s' "$line" | cut -d'|' -f9)")"
          printf '| %s | open | %s | - | %s | %s | %s | %s |\n' \
            "$id" "$due" "$created" "$NOW_ISO" "$source" "$title"
          continue
        fi
        printf '%s\n' "$line" ;;
      (*) printf '%s\n' "$line" ;;
    esac
  done < "$TASKS" > "$tmp" || return 1
  mv -f "$tmp" "$TASKS" || return 1
  return 0
}

# Lines of <file> matching <pattern> whose leading ISO date is >= <since>.
count_since() { # <file> <pattern> <since>
  local file="$1" pat="$2" since="$3" n=0 line d
  [ -f "$file" ] || { printf 0; return; }
  while IFS= read -r line; do
    d="${line:0:10}"
    [[ "$d" < "$since" ]] && continue
    case "$line" in (*"$pat"*) n=$((n+1));; esac
  done < "$file"
  printf '%s' "$n"
}

# ================================================================= BRIEF ====
mode_brief() {
  [ "$DUTY_BRIEFING" = enabled ] || quiet_out gated "brief: duty_briefing is disabled"
  [ "$DAILY_BRIEF" = enabled ]   || quiet_out gated "brief: daily_brief is disabled"
  [ "$NOTIFY" = enabled ]        || quiet_out gated "brief: channel_notifications is disabled"
  [ -n "$OWNER_ID" ]             || quiet_out no_member_id "brief: owner_member_id is not set — cannot message anyone"
  if grep -q "day=$TODAY sent=1" "$WORK/BRIEF.log" 2>/dev/null; then
    quiet_out already_sent "brief: already sent today ($TODAY)"
  fi
  [ -f "$TASKS" ] || quiet_out nothing_due "brief: no task file yet"

  local rows waking wake_ids cutoff overdue due_today upcoming overdue_aged one age n_o n_d n_u n_w
  rows="$(read_tasks "$TASKS" | jq -sc '.')" || fail_out "cannot read $TASKS"
  cutoff="$(day_plus "$LEAD_DAYS")"

  waking="$(printf '%s' "$rows" | jq -c --arg today "$TODAY" \
    '[ .[] | select(.status=="snoozed" and .snoozed_until!="-" and .snoozed_until<=$today) ]')"
  wake_ids="$(printf '%s' "$waking" | jq -r '.[].id')"
  if [ -n "$wake_ids" ]; then
    if printf '%s\n' "$wake_ids" | wake_snoozed; then
      log "woke $(num "$(printf '%s\n' "$wake_ids" | grep -c .)") snoozed task(s)"
      logev info preflight "brief woke $(num "$(printf '%s\n' "$wake_ids" | grep -c .)") snoozed row(s)"
      rows="$(read_tasks "$TASKS" | jq -sc '.')"
    else
      log "WARN could not rewrite the task file — snoozed rows left untouched"
      logev warn preflight "brief could not rewrite the task file"
    fi
  fi

  overdue="$(printf '%s' "$rows" | jq -c --arg today "$TODAY" \
    '[ .[] | select(.status=="open" and .due!="-" and .due<$today) ] | sort_by(.due)')"
  due_today="$(printf '%s' "$rows" | jq -c --arg today "$TODAY" \
    '[ .[] | select(.status=="open" and .due==$today) ]')"
  upcoming="$(printf '%s' "$rows" | jq -c --arg today "$TODAY" --arg cutoff "$cutoff" \
    '[ .[] | select(.status=="open" and .due!="-" and .due>$today and .due<=$cutoff) ] | sort_by(.due)')"

  overdue_aged='[]'
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    age="$(days_since "$(printf '%s' "$one" | jq -r '.due')")"
    overdue_aged="$(printf '%s' "$overdue_aged" \
      | jq -c --argjson e "$(printf '%s' "$one" | jq -c --argjson a "$age" '. + {overdue_days:$a}')" '. + [$e]')"
  done <<EOF
$(printf '%s' "$overdue" | jq -c '.[]')
EOF

  n_o="$(printf '%s' "$overdue_aged" | jq 'length')"
  n_d="$(printf '%s' "$due_today" | jq 'length')"
  n_u="$(printf '%s' "$upcoming" | jq 'length')"
  n_w="$(printf '%s' "$waking" | jq 'length')"
  [ "$(bad_rows)" -eq 0 ] || log "WARN $(bad_rows) unparseable task row(s) — reported, left in place"

  if [ $((n_o + n_d + n_u + n_w)) -eq 0 ]; then
    printf '%s brief day=%s sent=0 reason=nothing_due\n' "$NOW_ISO" "$TODAY" >> "$WORK/BRIEF.log"
    quiet_out nothing_due "brief: nothing due today ($TODAY) — quiet"
  fi

  log "brief for $TODAY: $n_o overdue, $n_d due today, $n_u upcoming, $n_w back from snooze"
  jq -n --arg mode "$MODE" --argjson cfg "$CONFIG_JSON" \
     --argjson overdue "$overdue_aged" --argjson due "$due_today" \
     --argjson upcoming "$upcoming" --argjson waking "$waking" \
     --argjson logs "$(logs_json)" \
     '{mode:$mode, nothing_to_do:false, config:$cfg, waking:$waking, overdue:$overdue,
       due_today:$due, upcoming:$upcoming, logs:$logs}'
  logev info preflight "brief $((n_o + n_d + n_u + n_w)) entries"
}

# ================================================================ REVIEW ====
mode_review() {
  [ "$DUTY_BRIEFING" = enabled ] || quiet_out gated "review: duty_briefing is disabled"
  [ "$WEEKLY_REVIEW" = enabled ] || quiet_out gated "review: weekly_review is disabled"
  [ "$NOTIFY" = enabled ]        || quiet_out gated "review: channel_notifications is disabled"
  [ -n "$OWNER_ID" ]             || quiet_out no_member_id "review: owner_member_id is not set — cannot message anyone"
  if grep -q "week=$ISOWEEK sent=1" "$WORK/REVIEW.log" 2>/dev/null; then
    quiet_out already_sent "review: already sent this week ($ISOWEEK)"
  fi

  local since rows arch open overdue stale done_week dropped_week added one age u
  local n_open n_done n_drop n_over n_stale n_snoozed
  since="$(day_plus -7)"
  rows="$(read_tasks "$TASKS" | jq -sc '.')"
  arch="$(read_tasks "$ARCHIVE" | jq -sc '.')"

  open="$(printf '%s' "$rows" | jq -c '[ .[] | select(.status=="open") ] | sort_by(.due=="-", .due, .created)')"
  overdue="$(printf '%s' "$rows" | jq -c --arg today "$TODAY" \
    '[ .[] | select(.status=="open" and .due!="-" and .due<$today) ]')"
  done_week="$(printf '%s' "$arch" | jq -c --arg since "$since" \
    '[ .[] | select(.status=="done" and (.updated|tostring) >= $since) ]')"
  dropped_week="$(printf '%s' "$arch" | jq -c --arg since "$since" \
    '[ .[] | select(.status=="dropped" and (.updated|tostring) >= $since) ]')"
  added="$(printf '%s %s' "$rows" "$arch" | jq -sc --arg since "$since" \
    'add | [ .[] | select((.created|tostring) >= $since) ] | length')"

  stale='[]'
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    u="$(printf '%s' "$one" | jq -r '.updated' | cut -c1-10)"
    age="$(days_since "$u")"
    if [ "$age" -gt "$STALE_DAYS" ]; then
      stale="$(printf '%s' "$stale" \
        | jq -c --argjson e "$(printf '%s' "$one" | jq -c --argjson a "$age" '. + {idle_days:$a}')" '. + [$e]')"
    fi
  done <<EOF
$(printf '%s' "$open" | jq -c '.[]')
EOF

  n_open="$(printf '%s' "$open" | jq 'length')"
  n_done="$(printf '%s' "$done_week" | jq 'length')"
  n_drop="$(printf '%s' "$dropped_week" | jq 'length')"
  n_over="$(printf '%s' "$overdue" | jq 'length')"
  n_stale="$(printf '%s' "$stale" | jq 'length')"
  n_snoozed="$(printf '%s' "$rows" | jq '[ .[] | select(.status=="snoozed") ] | length')"
  [ "$(bad_rows)" -eq 0 ] || log "WARN $(bad_rows) unparseable task row(s) — reported, left in place"

  if [ $((n_open + n_done + n_drop)) -eq 0 ]; then
    printf '%s review week=%s sent=0 reason=nothing_due\n' "$NOW_ISO" "$ISOWEEK" >> "$WORK/REVIEW.log"
    quiet_out nothing_due "review: nothing closed, dropped or open this week — quiet"
  fi

  log "review $ISOWEEK: $n_done done, $n_drop dropped, $n_open open ($n_over overdue, $n_stale stale)"
  jq -n --arg mode "$MODE" --argjson cfg "$CONFIG_JSON" --arg since "$since" \
     --argjson done_week "$done_week" --argjson dropped_week "$dropped_week" \
     --argjson open "$open" --argjson overdue "$overdue" --argjson stale "$stale" \
     --argjson counters "$(jq -n --argjson done "$n_done" --argjson dropped "$n_drop" \
        --argjson added "$added" --argjson open "$n_open" --argjson overdue "$n_over" \
        --argjson stale "$n_stale" --argjson snoozed "$n_snoozed" \
        '{done:$done, dropped:$dropped, added:$added, open:$open, overdue:$overdue,
          stale:$stale, snoozed:$snoozed}')" \
     --argjson logs "$(logs_json)" \
     '{mode:$mode, nothing_to_do:false, config:$cfg, since:$since, done_week:$done_week,
       dropped_week:$dropped_week, open:$open, overdue:$overdue, stale:$stale,
       counters:$counters, logs:$logs}'
  logev info preflight "review $n_open open / $n_done done"
}

# ================================================================= AUDIT ====
CHECKS='[]'
check() { # <id> <ok|warn|fail> <detail>
  CHECKS="$(printf '%s' "$CHECKS" | jq -c --arg id "$1" --arg st "$2" --arg d "$3" \
            '. + [{id:$id, status:$st, detail:$d}]')"
}

audit_cadence() { # <log file> <check id> <max age days> <enabled?>
  local file="$WORK/$1" last age
  if [ "$4" != enabled ]; then check "$2" ok "not enabled — no cadence expected"; return; fi
  last="$(tail -1 "$file" 2>/dev/null | cut -c1-10)"
  case "$last" in
    ([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    (*) check "$2" warn "no run logged yet"; return;;
  esac
  age="$(days_since "$last")"
  if [ "$age" -gt "$3" ]; then check "$2" fail "last run $age day(s) ago (expected within $3)"
  else check "$2" ok "last run $age day(s) ago"; fi
}

mode_audit() {
  local since cut14 cut90
  since="$(day_plus -7)"; cut14="$(day_plus -14)"; cut90="$(day_plus -90)"

  # --- structure: the same verification onboarding ends with, offline.
  # PA_SKIP_STRUCTURE is set by verify-onboarding.sh --live when it probes this
  # mode, so the two never call each other in a loop.
  if [ "${PA_SKIP_STRUCTURE:-0}" = 1 ]; then
    check structure warn "skipped — invoked from verify-onboarding.sh"
  elif [ -f "$SCRIPT_DIR/verify-onboarding.sh" ]; then
    local vout vfails
    vout="$(bash "$SCRIPT_DIR/verify-onboarding.sh" 2>&1)"
    vfails="$(num "$(printf '%s\n' "$vout" | grep -c '^FAIL ')")"
    if [ "$vfails" -gt 0 ]; then
      check structure fail "$vfails failing check(s) — run verify-onboarding.sh and apply each fix"
    else
      check structure ok "verify-onboarding.sh passes offline"
    fi
  else
    check structure warn "verify-onboarding.sh not found — structure not measured"
  fi

  # --- the invariants the shared volume forces
  if [ -e "$WORK/.git" ]; then
    check work_not_git fail "work/.git exists — the shared volume corrupts a git dir here"
  else
    check work_not_git ok "work/ is a plain data directory"
  fi
  local nfs; nfs="$(num "$(find "$WORK" -name '.nfs*' 2>/dev/null | grep -c .)")"
  if [ "$nfs" -gt 0 ]; then check nfs_junk warn "$nfs .nfs* file(s) under work/ — concurrent access signal"
  else check nfs_junk ok "no .nfs* junk"; fi

  # --- task file shape
  local rows dup bad_status counter maxid nbad
  rows="$(read_tasks "$TASKS" | jq -sc '.')"
  nbad="$(bad_rows)"
  dup="$(printf '%s' "$rows" | jq '[ .[].id ] | group_by(.) | map(select(length>1)) | length')"
  bad_status="$(printf '%s' "$rows" | jq '[ .[] | select(.status!="open" and .status!="snoozed") ] | length')"
  if [ "$nbad" -gt 0 ] || [ "$dup" -gt 0 ] || [ "$bad_status" -gt 0 ]; then
    check tasks_shape fail "$nbad unparseable, $dup duplicate id(s), $bad_status row(s) with a non-live status"
  else
    check tasks_shape ok "$(printf '%s' "$rows" | jq 'length') live row(s), all well-formed"
  fi
  counter="$(head -1 "$WORK/TASKS-counter" 2>/dev/null | tr -cd '0-9')"
  maxid="$( { printf '%s' "$rows" | jq -r '.[].id'; read_tasks "$ARCHIVE" | jq -r '.id'; } 2>/dev/null \
            | sed -e "s/^$TASK_PREFIX-//" -e 's/^0*//' | sort -n | tail -1)"
  maxid="$(num "$maxid")"
  if [ -z "$counter" ]; then
    check tasks_counter fail "work/TASKS-counter missing or not a number — ids could be reused"
  elif [ "$counter" -lt "$maxid" ]; then
    check tasks_counter fail "counter $counter is below the highest id $maxid — ids could be reused"
  else
    check tasks_counter ok "counter at $counter"
  fi

  # --- orphaned note files
  local orphans=0 f id
  if [ -d "$WORK/TASKS" ]; then
    for f in "$WORK/TASKS"/*.md; do
      [ -e "$f" ] || continue
      id="$(basename "$f" .md)"
      grep -q "^| *$id *|" "$TASKS" 2>/dev/null && continue
      grep -q "^| *$id *|" "$ARCHIVE" 2>/dev/null && continue
      orphans=$((orphans+1))
    done
  fi
  if [ "$orphans" -gt 0 ]; then check tasks_orphans warn "$orphans note file(s) without a task row"
  else check tasks_orphans ok "no orphaned note files"; fi

  # --- cadence of the enabled proactive runs
  audit_cadence BRIEF.log cadence_brief 3 "$DAILY_BRIEF"
  audit_cadence REVIEW.log cadence_review 8 "$WEEKLY_REVIEW"
  audit_cadence AUDIT.log cadence_audit 8 enabled

  # --- error scan over the week's summary logs. No log file at all means the scan
  # could not look, which is never the same answer as "found nothing".
  local errs
  if ls "$WORK"/*.log >/dev/null 2>&1; then
    errs="$(num "$(grep -h 'ERROR:' "$WORK"/*.log 2>/dev/null | grep -c .)")"
    if [ "$errs" -gt 0 ]; then check errors warn "$errs ERROR line(s) in work/*.log"
    else check errors ok "no ERROR lines in the summary logs"; fi
  else
    check errors warn "no summary logs yet — not measured"
  fi

  # --- failures[]: the week's error events, grouped into signatures for diagnosis
  local failures='[]'
  if ls "$WORK"/logs/events-*.jsonl >/dev/null 2>&1; then
    failures="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null \
      | jq -sc --arg since "$since" '
          [ .[] | select(.level=="error") | select((.ts|tostring) >= $since) ]
          | group_by(.event + "|" + ((.msg // "") | gsub("[0-9]+";"N")))
          | map({event: .[0].event,
                 signature: ((.[0].msg // "") | gsub("[0-9]+";"N")),
                 count: length, first: ([.[].ts] | min), last: ([.[].ts] | max)})' 2>/dev/null)"
    case "$failures" in ('') failures='[]';; esac
  fi

  # --- retention sweeps (the audit's only routine local writes besides its log line)
  local removed=0 d
  for f in "$WORK"/logs/events-*.jsonl; do
    [ -e "$f" ] || continue
    d="$(basename "$f" .jsonl | sed 's/^events-//')"
    if [[ "$d" < "$cut14" ]]; then rm -f "$f" 2>/dev/null && removed=$((removed+1)); fi
  done
  local trimmed=0
  if [ -f "$WORK/INBOX.log" ] && [ -n "$SCRATCH" ]; then
    local total keep line
    total="$(num "$(grep -c . "$WORK/INBOX.log" 2>/dev/null)")"
    while IFS= read -r line; do
      d="${line:0:10}"
      [[ "$d" < "$cut90" ]] || printf '%s\n' "$line"
    done < "$WORK/INBOX.log" > "$SCRATCH/inbox.new"
    keep="$(num "$(grep -c . "$SCRATCH/inbox.new" 2>/dev/null)")"
    trimmed=$((total - keep))
    if [ "$trimmed" -gt 0 ]; then mv -f "$SCRATCH/inbox.new" "$WORK/INBOX.log"; fi
  fi
  check retention ok "removed $removed old events file(s), trimmed $trimmed ledger line(s)"

  # --- memory bounds
  local observed
  observed="$(num "$(sed -n '/^## Observed/,/^## /p' "$WORK/MEMORY.md" 2>/dev/null | grep -c '^- \[observed')")"
  if [ "$observed" -gt 30 ]; then check memory_bounds warn "$observed observed entries (cap 30) — consolidate in the review"
  else check memory_bounds ok "$observed observed memory entries"; fi

  # --- disk
  local kb; kb="$(du -sk "$WORK" 2>/dev/null | cut -f1)"
  case "$kb" in
    (''|*[!0-9]*) check disk warn "volume usage not measured";;
    (*) if [ "$kb" -gt 524288 ]; then check disk warn "work/ is $((kb/1024)) MB"
        else check disk ok "work/ is $((kb/1024)) MB"; fi;;
  esac

  # --- definition cleanliness & version currency (read-only)
  local dirty cur latest adopted status_out
  if status_out="$(git -C "$HOME_DIR" status --porcelain 2>/dev/null)"; then
    dirty="$(num "$(printf '%s' "$status_out" | grep -c .)")"
    if [ "$dirty" -gt 0 ]; then check definition_clean fail "$dirty uncommitted path(s) in the definition checkout"
    else check definition_clean ok "definition checkout is clean"; fi
  elif [ -n "$DEFINITION_REPO" ]; then
    check definition_clean fail "no git checkout at $HOME_DIR — the definition cannot be updated or verified"
  else
    check definition_clean warn "no git checkout at $HOME_DIR — local-only: no version check, no self-update, no definition PR"
  fi
  cur="$(head -1 "$HOME_DIR/VERSION" 2>/dev/null)"
  adopted="$(head -1 "$WORK/VERSION" 2>/dev/null)"
  if git -C "$HOME_DIR" fetch -q origin main 2>/dev/null; then
    latest="$(git -C "$HOME_DIR" show origin/main:VERSION 2>/dev/null | head -1)"
  else latest=""; fi
  if [ -z "$latest" ]; then
    check version warn "latest version not measured (fetch failed) — checked out ${cur:-?}, adopted ${adopted:-?}"
  elif [ "$cur" != "$latest" ] || [ "$cur" != "$adopted" ]; then
    check version warn "checked out ${cur:-?}, latest $latest, adopted ${adopted:-?} — upgrade in the direct session"
  else check version ok "up to date ($cur)"; fi

  # --- toolchain shims (the workaround is reported, never absorbed)
  local shimmed=""
  if command -v toolpath_shimmed >/dev/null 2>&1; then shimmed="$(toolpath_shimmed jq gh 2>/dev/null)"; fi
  if [ -n "$shimmed" ]; then check tool_shims warn "behind a mise shim: $shimmed — the fix belongs in the pod image"
  else check tool_shims ok "no shimmed CLI tools"; fi

  # --- leftover temp dirs
  local tmps; tmps="$(num "$(ls -d /tmp/personal-assistant-* 2>/dev/null | grep -c .)")"
  if [ "$tmps" -gt 0 ]; then check tmp warn "$tmps leftover /tmp/personal-assistant-* dir(s)"
  else check tmp ok "no leftover temp directories"; fi

  # --- the week in numbers
  local runs_brief runs_review sent_brief sent_review idle inbound declined n_ok n_warn n_fail
  runs_brief="$(count_since "$WORK/BRIEF.log" 'brief ' "$since")"
  runs_review="$(count_since "$WORK/REVIEW.log" 'review ' "$since")"
  sent_brief="$(count_since "$WORK/BRIEF.log" 'sent=1' "$since")"
  sent_review="$(count_since "$WORK/REVIEW.log" 'sent=1' "$since")"
  idle="$(( $(count_since "$WORK/BRIEF.log" 'sent=0' "$since") + $(count_since "$WORK/REVIEW.log" 'sent=0' "$since") ))"
  inbound="$(count_since "$WORK/INBOX.log" 'intent=' "$since")"
  declined="$(count_since "$WORK/INBOX.log" 'action=declined' "$since")"

  n_ok="$(printf '%s' "$CHECKS" | jq '[ .[] | select(.status=="ok") ] | length')"
  n_warn="$(printf '%s' "$CHECKS" | jq '[ .[] | select(.status=="warn") ] | length')"
  n_fail="$(printf '%s' "$CHECKS" | jq '[ .[] | select(.status=="fail") ] | length')"
  log "audit: $n_ok ok, $n_warn warn, $n_fail fail; $(printf '%s' "$failures" | jq 'length') failure signature(s)"

  jq -n --arg mode "$MODE" --argjson cfg "$CONFIG_JSON" --arg since "$since" \
     --argjson checks "$CHECKS" --argjson failures "$failures" \
     --argjson stats "$(jq -n --argjson rb "$runs_brief" --argjson rr "$runs_review" \
        --argjson sb "$sent_brief" --argjson sr "$sent_review" --argjson idle "$idle" \
        --argjson inbound "$inbound" --argjson declined "$declined" \
        '{brief_runs:$rb, review_runs:$rr, briefs_sent:$sb, reviews_sent:$sr,
          idle_runs:$idle, inbound_handled:$inbound, inbound_declined:$declined}')" \
     --argjson summary "$(jq -n --argjson ok "$n_ok" --argjson warn "$n_warn" --argjson fail "$n_fail" \
        '{ok:$ok, warn:$warn, fail:$fail}')" \
     --argjson logs "$(logs_json)" \
     '{mode:$mode, nothing_to_do:false, config:$cfg, since:$since, checks:$checks,
       summary:$summary, failures:$failures, stats:$stats, logs:$logs}'
  logev info preflight "audit $n_ok ok / $n_warn warn / $n_fail fail"
}

case "$MODE" in
  brief)  mode_brief ;;
  review) mode_review ;;
  audit)  mode_audit ;;
  *) fail_out "unknown mode: $MODE" ;;
esac
