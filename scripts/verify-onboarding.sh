#!/usr/bin/env bash
# verify-onboarding.sh — one-shot structure verification of an onboarded agent.
#
# Runs twice during ONBOARDING — `--config` right after `work/CONFIG.md` is
# written, then a full run at the end (after the sentinel) — and again as an
# upgrade step whenever a version changes what onboarding produces, and weekly
# from the audit. It checks that onboarding produced what it promises: the
# definition checkout at $HOME and the work/ state files, with the STRUCTURE the
# templates define. Shape only — required files, required keys, enum values,
# table headers; the data inside is never judged. The goal: every deployed
# instance looks the same apart from its configuration values.
#
# Detects, never repairs (same contract as preflight.sh): no external writes, no
# local writes beyond one structured log event. Every FAIL line carries a `fix:`
# instruction for the agent to apply; re-run after fixing until it prints PASS.
#
#   ok   <check> — <detail>                      passed
#   warn <check> — <detail>                      informational, never blocks
#   FAIL <check> — <problem> — fix: <instruction>
#
#   --config   the CONFIG block only. For mid-onboarding use, before the
#              schedules, work/VERSION and the sentinel exist.
#   (none)     every offline block: definition, work/, CONFIG.
#   --live     the offline blocks plus the "does it actually work" pass —
#              remotes reachable, and one read-only `preflight.sh <mode>` per
#              scheduled run type as end-to-end proof.
#
# Exit 0 iff nothing FAILed.

set -u
export LC_ALL=C

LIVE=0; STRUCTURE=1
case "${1:-}" in
  (--live)   LIVE=1;;
  (--config) STRUCTURE=0;;
  ('') ;;
  (*) printf 'usage: %s [--config|--live]\n' "$0" >&2; exit 2;;
esac

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SENTINEL="$HOME_DIR/.personal-assistant-onboarded"
TASK_HEADER='| id | status | due | snoozed_until | created | updated | source | title |'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

CHECKS=0; FAILS=0; WARNS=0
ok()   { CHECKS=$((CHECKS+1)); printf 'ok   %s — %s\n' "$1" "$2"; }
fail() { CHECKS=$((CHECKS+1)); FAILS=$((FAILS+1)); printf 'FAIL %s — %s — fix: %s\n' "$1" "$2" "$3"; }
warn() { WARNS=$((WARNS+1)); printf 'warn %s — %s\n' "$1" "$2"; }

# The same readers the runtime uses, from the same file — this script judges the
# CONFIG.md that preflight.sh will read, so a second copy of the parser here
# would be the very drift it exists to catch.
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }

has_heading() { grep -qxF "$2" "$1" 2>/dev/null; }

# Every key the runtime knows (docs/config.md). A bullet that is not on this list
# is invisible to the runtime, so it FAILs rather than passing silently.
KNOWN_KEYS="display_name owner_name owner_channel owner_member_id timezone working_hours
dm_control channel_notifications daily_brief weekly_review audit_report
duty_tasks duty_briefing duty_answers duty_drafting web_research
task_prefix reminder_lead_days stale_task_days definition_repo log_level"
REQUIRED_KEYS="display_name owner_channel owner_member_id timezone working_hours dm_control
channel_notifications daily_brief weekly_review audit_report
duty_tasks duty_briefing duty_answers duty_drafting task_prefix definition_repo"
ENABLE_KEYS="channel_notifications daily_brief weekly_review audit_report
duty_tasks duty_briefing duty_answers duty_drafting web_research"

if [ "$STRUCTURE" = 1 ]; then
  # ----------------------------------------------------------- definition ----
  if [ -d "$HOME_DIR/.git" ]; then
    ok definition_repo "definition checkout present at $HOME_DIR"
    if [ -z "$(git -C "$HOME_DIR" status --porcelain 2>/dev/null)" ]; then
      ok definition_clean "no uncommitted or untracked paths leak into the definition"
    else
      fail definition_clean "git status is not clean" \
        "inspect 'git -C $HOME_DIR status --porcelain'; anything under work/, .ssh, .claude or .config showing up means .gitignore lost its allowlist shape — restore it, never 'git clean'"
    fi
  elif [ -n "$(cfg definition_repo)" ]; then
    fail definition_repo "no git checkout at $HOME_DIR, but definition_repo is set" \
      "re-run ONBOARDING.md Step 1 (init + fetch + hard reset; never clone into \$HOME)"
  else
    warn definition_repo "no git checkout at $HOME_DIR — local-only: no version check, no self-update, no definition PR (docs/persistence.md)"
  fi
  if [ "$(grep -v '^[[:space:]]*#' "$HOME_DIR/.gitignore" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)" = '/*' ]; then
    ok gitignore_allowlist ".gitignore ignores everything first, then re-includes the definition"
  else
    fail gitignore_allowlist ".gitignore is not an allowlist" \
      "its first rule must be '/*' — restore it from the definition repo before any git add"
  fi
  if [ -f "$SENTINEL" ] && grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$SENTINEL"; then
    ok sentinel "onboarding sentinel present ($(head -1 "$SENTINEL"))"
  else
    fail sentinel "missing or malformed $SENTINEL" \
      "write a UTC timestamp into it: date -u +%Y-%m-%dT%H:%M:%SZ > \"$SENTINEL\""
  fi

  # ---------------------------------------------------------------- work/ ----
  if [ -d "$WORK" ]; then ok work_dir "work/ present"
  else fail work_dir "no $WORK" "re-run ONBOARDING.md Step 2"; fi
  if [ -e "$WORK/.git" ]; then
    fail work_not_git "work/ contains a .git" \
      "remove it: the shared volume corrupts a git dir here; backups run in a tmpfs clone (docs/persistence.md)"
  else
    ok work_not_git "work/ is a plain data directory"
  fi
  [ -f "$WORK/AGENTS.md" ] && ok work_pointer "work/AGENTS.md pointer present" \
    || fail work_pointer "missing work/AGENTS.md" "re-run ONBOARDING.md Step 2c"

  # persona / duties / memory: the files that make this instance itself
  if has_heading "$WORK/PERSONA.md" '## Identity' && has_heading "$WORK/PERSONA.md" '## Voice' \
     && has_heading "$WORK/PERSONA.md" '## Boundaries' && has_heading "$WORK/PERSONA.md" '## Notes from the owner'; then
    ok persona "work/PERSONA.md has all four sections"
  else
    fail persona "work/PERSONA.md missing or incomplete" \
      "it needs '## Identity', '## Voice', '## Boundaries' and '## Notes from the owner' (ONBOARDING.md Step 3, docs/preferences.md)"
  fi
  if has_heading "$WORK/DUTIES.md" '## Standing duties' && has_heading "$WORK/DUTIES.md" '## Not my job'; then
    ok duties "work/DUTIES.md has both sections"
  else
    fail duties "work/DUTIES.md missing or incomplete" \
      "it needs '## Standing duties' and '## Not my job' (ONBOARDING.md Step 3, docs/duties.md)"
  fi
  if has_heading "$WORK/MEMORY.md" '## Preferences' && has_heading "$WORK/MEMORY.md" '## Observed'; then
    ok memory "work/MEMORY.md has both sections"
  else
    fail memory "work/MEMORY.md missing or incomplete" \
      "it needs '## Preferences' and '## Observed' (ONBOARDING.md Step 2b) — never overwrite an existing one"
  fi
  [ -f "$WORK/LESSONS.md" ] && ok lessons "work/LESSONS.md present" \
    || fail lessons "missing work/LESSONS.md" "seed it from ONBOARDING.md Step 2b"

  # task files: the header is the parsing contract (docs/tasks.md)
  for f in TASKS TASKS-archive; do
    if has_heading "$WORK/$f.md" "$TASK_HEADER"; then
      ok "${f}_header" "work/$f.md carries the documented table header"
    else
      fail "${f}_header" "work/$f.md missing or with a changed header" \
        "restore the exact header from docs/tasks.md → Row format; every reader parses those columns"
    fi
  done
  if [ -d "$WORK/TASKS" ]; then ok tasks_notes_dir "work/TASKS/ present"
  else fail tasks_notes_dir "missing work/TASKS/ note directory" "mkdir -p \"$WORK/TASKS\""; fi
  counter="$(head -1 "$WORK/TASKS-counter" 2>/dev/null | tr -cd '0-9')"
  if [ -n "$counter" ]; then ok tasks_counter "id counter at $counter"
  else fail tasks_counter "work/TASKS-counter missing or not a number" \
    "write the highest allocated id number into it (0 on a fresh instance) — ids are never reused"; fi
  [ -f "$WORK/INBOX.log" ] && ok inbox_ledger "work/INBOX.log present" \
    || fail inbox_ledger "missing work/INBOX.log" "create it empty: touch \"$WORK/INBOX.log\" (docs/logging.md)"

  # adopted version
  if [ -f "$WORK/VERSION" ] && [ -f "$HOME_DIR/VERSION" ]; then
    if [ "$(head -1 "$WORK/VERSION")" = "$(head -1 "$HOME_DIR/VERSION")" ]; then
      ok version_adopted "work/VERSION matches the checkout ($(head -1 "$WORK/VERSION"))"
    else
      fail version_adopted "adopted $(head -1 "$WORK/VERSION") != checked out $(head -1 "$HOME_DIR/VERSION")" \
        "apply the CHANGELOG Upgrade blocks in between, then write the new version (docs/persistence.md)"
    fi
  else
    fail version_adopted "work/VERSION missing" "head -1 \"$HOME_DIR/VERSION\" > \"$WORK/VERSION\""
  fi
fi

# ------------------------------------------------------------------- CONFIG
if [ ! -f "$CONFIG" ]; then
  fail config_file "no $CONFIG" "run ONBOARDING.md Step 3 — the runtime falls back to defaults and can message nobody"
else
  ok config_file "work/CONFIG.md present"
  for k in $REQUIRED_KEYS; do
    if grep -qE "^- $k:" "$CONFIG"; then
      case "$k" in
        (owner_member_id)
          [ -n "$(cfg "$k")" ] && ok "cfg_$k" "set" \
            || warn "cfg_$k" "empty — the agent can reply, but no proactive run may send anything" ;;
        (definition_repo)
          [ -n "$(cfg "$k")" ] && ok "cfg_$k" "$(cfg "$k")" \
            || warn "cfg_$k" "empty — local-only: no version check, no self-update, no definition PR (docs/persistence.md)" ;;
        (*)
          [ -n "$(cfg "$k")" ] && ok "cfg_$k" "$(cfg "$k")" \
            || fail "cfg_$k" "key present but empty" "give it a value (docs/config.md) — an empty value is not the documented default" ;;
      esac
    else
      fail "cfg_$k" "required key '$k' is missing" \
        "add a '- $k: <value>' bullet (docs/config.md); the runtime reads that exact shape and nothing else"
    fi
  done
  for k in $ENABLE_KEYS; do
    v="$(cfg "$k")"
    case "$v" in
      (''|enabled|disabled) ;;
      (*) fail "enum_$k" "'$k: $v' is not enabled|disabled" "set it to 'enabled' or 'disabled' (docs/config.md)" ;;
    esac
  done
  case "$(cfg dm_control)" in
    (''|answers|tasks|full) ;;
    (*) fail enum_dm_control "dm_control is not answers|tasks|full" "set one of the three documented levels (docs/config.md)" ;;
  esac
  case "$(cfg owner_channel)" in
    (''|slack|telegram) ;;
    (*) fail enum_owner_channel "owner_channel is not slack|telegram" "set the channel the platform granted (docs/config.md)" ;;
  esac
  tz="$(cfg timezone)"
  if [ -n "$tz" ] && ! TZ="$tz" date +%Y-%m-%d >/dev/null 2>&1; then
    fail config_timezone "timezone '$tz' is not accepted by date" "use an IANA name such as Europe/Prague (docs/config.md)"
  fi
  # a bullet that is not a known key is invisible to the runtime — a typo, not a comment
  unknown=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case " $(printf '%s' "$KNOWN_KEYS" | tr '\n' ' ') " in
      (*" $k "*) ;;
      (*) unknown="${unknown:+$unknown }$k";;
    esac
  done <<EOF
$(grep -oE '^- [a-z_]+:' "$CONFIG" 2>/dev/null | sed -e 's/^- //' -e 's/:$//')
EOF
  if [ -n "$unknown" ]; then
    fail config_unknown_keys "unknown config bullet(s): $unknown" \
      "the runtime reads only the documented keys — fix the spelling or move the line out of the '- key: value' shape (docs/config.md)"
  else
    ok config_unknown_keys "every '- key:' bullet is a known key"
  fi
fi

# --------------------------------------------------------------------- live
if [ "$LIVE" = 1 ]; then
  if command -v git >/dev/null 2>&1 && [ -d "$HOME_DIR/.git" ]; then
    if git -C "$HOME_DIR" ls-remote origin HEAD >/dev/null 2>&1; then
      ok live_definition_remote "definition remote reachable"
    elif [ -n "$(cfg definition_repo)" ]; then
      fail live_definition_remote "definition_repo is set but its remote cannot be reached" \
        "check the GitHub connection and 'gh auth setup-git', or clear definition_repo to run local-only (docs/persistence.md)"
    else
      warn live_definition_remote "definition remote unreachable — local-only: no version check, no self-update, no definition PR (docs/persistence.md)"
    fi
  else
    warn live_definition_remote "no git checkout or git missing — not measured; the definition_repo check says whether that is local-only"
  fi

  if [ -n "${GITHUB_REPO_WORK:-}" ]; then
    if git ls-remote "https://github.com/$GITHUB_REPO_WORK" HEAD >/dev/null 2>&1; then
      ok live_state_remote "state backup remote reachable"
    else
      fail live_state_remote "GITHUB_REPO_WORK is set but unreachable" \
        "create the (private) repo and grant access, or unset the variable to run local-only (docs/persistence.md)"
    fi
  else
    warn live_state_remote "GITHUB_REPO_WORK unset — state lives on the volume only and is not reconstructable"
  fi

  # The channel itself is only reachable through the platform's MCP tools, which
  # a shell cannot call: reported as a warn so the agent runs the probe itself,
  # never as a silent pass.
  warn live_channel "channel reachability is not scriptable — send yourself one test message via mcp__platform-outbound__send_channel_message and confirm it arrives"

  for m in brief review audit; do
    out="$(PA_SKIP_STRUCTURE=1 bash "$SCRIPT_DIR/preflight.sh" "$m" 2>/dev/null)"
    if printf '%s' "$out" | jq -e '.mode' >/dev/null 2>&1; then
      if printf '%s' "$out" | jq -e '.error' >/dev/null 2>&1; then
        fail "live_preflight_$m" "preflight $m reported: $(printf '%s' "$out" | jq -r '.error')" \
          "fix the cause it names, then re-run this script"
      else
        ok "live_preflight_$m" "preflight $m emits a valid worklist (nothing_to_do=$(printf '%s' "$out" | jq -r '.nothing_to_do'))"
      fi
    else
      fail "live_preflight_$m" "preflight $m did not emit JSON" \
        "run 'bash \$HOME/scripts/preflight.sh $m' and read its stderr; a broken pre-flight degrades every run of that type"
    fi
  done
fi

# ------------------------------------------------------------------- summary
if [ "$LIVE" = 1 ]; then SCOPE="structure+live"
elif [ "$STRUCTURE" = 1 ]; then SCOPE="structure"
else SCOPE="config"; fi
if [ "$FAILS" -eq 0 ]; then
  printf 'PASS (%s) — %d checks passed, %d warning(s)\n' "$SCOPE" "$CHECKS" "$WARNS"
  logev info onboarding_verify "PASS $SCOPE ($CHECKS checks, $WARNS warnings)"
  exit 0
else
  printf 'RESULT (%s): %d of %d checks FAILED — apply each fix above, then re-run this script until it prints PASS.\n' "$SCOPE" "$FAILS" "$CHECKS"
  logev error onboarding_verify "FAILED $SCOPE ($FAILS of $CHECKS checks) — agent must repair and re-run"
  exit 1
fi
