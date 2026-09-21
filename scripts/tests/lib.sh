#!/usr/bin/env bash
# lib.sh — shared helpers for the offline tests. Sourced, never run directly.
#
# Every test gets its own sandbox: a temp $HOME with a work/ tree, so nothing
# touches a real deployment. Tests are offline — the pre-flight talks to no
# external system, so no CLI stubs are needed; a test that ever does need one
# prepends scripts/tests/bin to PATH (see run.sh).
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PREFLIGHT="$SCRIPTS_DIR/preflight.sh"
VERIFY="$SCRIPTS_DIR/verify-onboarding.sh"

FAILURES=0
assert_eq() { # <expected> <actual> <what>
  if [ "$1" = "$2" ]; then printf '  ok   %s (%s)\n' "$3" "$2"
  else printf '  FAIL %s: expected %s, got %s\n' "$3" "$1" "$2"; FAILURES=$((FAILURES+1)); fi
}
assert_contains() { # <needle> <haystack> <what>
  case "$2" in (*"$1"*) printf '  ok   %s\n' "$3";;
    (*) printf '  FAIL %s: %s not found\n' "$3" "$1"; FAILURES=$((FAILURES+1));; esac
}

sandbox() { # -> exports SB, WORK; call once per test
  SB="$(mktemp -d "${TMPDIR:-/tmp}/pa-test.XXXXXX")"
  WORK="$SB/work"
  mkdir -p "$WORK/TASKS" "$WORK/logs"
  export HOME_ORIG="${HOME:-}"
  trap 'rm -rf "$SB"' EXIT
}

# YYYY-MM-DD, signed offset in days, UTC (the sandbox always runs in UTC).
# BSD date needs an explicit sign, GNU does not — normalize before either.
day() {
  local n="${1:-0}"; case "$n" in ([!+-]*) n="+$n";; esac
  date -u -d "$n days" +%Y-%m-%d 2>/dev/null || date -u -v"${n}d" +%Y-%m-%d
}
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

write_config() { # <<'EOF' body of extra/overriding bullets
  cat > "$WORK/CONFIG.md" <<EOF
# Configuration

- display_name: Assistant
- owner_name: alice
- owner_channel: slack
- owner_member_id: U0123ABCD
- timezone: UTC
- working_hours: 09:00-17:00
- dm_control: tasks
- channel_notifications: enabled
- daily_brief: enabled
- weekly_review: enabled
- audit_report: enabled
- duty_tasks: enabled
- duty_briefing: enabled
- duty_answers: enabled
- duty_drafting: disabled
- web_research: enabled
- stranger_policy: decline
- memory_inference: enabled
- task_prefix: T
- reminder_lead_days: 1
- stale_task_days: 14
- definition_repo: acme/personal-assistant
- log_level: info
EOF
}

task_header() { # <file>
  {
    printf '# Tasks\n\n'
    printf '| id | status | due | snoozed_until | created | updated | source | title |\n'
    printf '| --- | --- | --- | --- | --- | --- | --- | --- |\n'
  } > "$1"
}

add_row() { # <file> <id> <status> <due> <snoozed> <created> <updated> <source> <title>
  printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >> "$1"
}

run_preflight() { # <mode> -> JSON on stdout
  HOME="$SB" WORK_DIR="$WORK" TZ=UTC bash "$PREFLIGHT" "$1" 2>/dev/null
}
