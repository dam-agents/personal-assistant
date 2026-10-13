#!/usr/bin/env bash
# The artifact gate must pass a self-contained page and stop one that loads, calls,
# or carries a credential — naming lines, never the text. The audit must fail any
# ledger line past Private that no owner message asked for, and never pass one while
# artifact_sharing is never (docs/privacy.md -> Artifacts).
set -u
. "$(dirname "$0")/lib.sh"
sandbox

write_config
task_header "$WORK/TASKS.md"
task_header "$WORK/TASKS-archive.md"
echo 0 > "$WORK/TASKS-counter"
mkdir -p "$WORK/artifacts"
page="$WORK/artifacts/page.html"
rule_lines() { printf '%s' "$1" | jq -r --arg r "$2" '[.findings[] | select(.rule==$r) | .lines[]] | map(tostring) | join(",")'; }

# --- a self-contained page: inline style and script, a data: image, a link to click
cat > "$page" <<'EOF'
<!doctype html>
<html><head><style>body{font:14px sans-serif}</style></head>
<body><svg xmlns="http://www.w3.org/2000/svg"><rect width="4" height="4"/></svg>
<img src="data:image/png;base64,iVBORw0KGgo=">
<a href="https://example.com/help">help</a>
<script>document.body.dataset.ready = "1"; window.location.hash = "#top";</script>
</body></html>
EOF
out="$(run_preflight artifact "$page")"
assert_eq artifact "$(printf '%s' "$out" | jq -r '.mode')" "the gate emits its mode"
assert_eq true "$(printf '%s' "$out" | jq -r '.ok')" "a self-contained page passes"
assert_eq UTC "$(printf '%s' "$out" | jq -r '.config.timezone')" "the gate carries config like every mode"

# --- each way a page reaches out is its own finding, by line number
cat > "$page" <<'EOF'
<!doctype html>
<html><head>
<link rel="stylesheet" href="https://cdn.example.net/x.css">
<script src="//cdn.example.net/chart.js"></script>
<style>@import url("https://fonts.example.net/f.css"); body{background:url(https://img.example.net/b.png)}</style>
</head><body>
<script>fetch("/x"); new Image().src = 'https://t.example.net/p.gif';</script>
<form action="https://collect.example.net/"></form>
</body></html>
EOF
out="$(run_preflight artifact "$page")"
assert_eq false "$(printf '%s' "$out" | jq -r '.ok')" "a page that loads from elsewhere is stopped"
assert_eq "3,4,5,7,8" "$(rule_lines "$out" remote_load)" "remote loads named by line"
assert_eq "7" "$(rule_lines "$out" network_call)" "a network call named by line"

# --- a credential is a finding, and the finding never carries it.
# The token is assembled at runtime so this file holds no scanner-matchable literal.
printf '<p>ghp_%036d</p>\n' 0 > "$page"
out="$(run_preflight artifact "$page")"
assert_eq "1" "$(rule_lines "$out" secret)" "a credential in the page is stopped"
assert_eq 0 "$(printf '%s' "$out" | grep -c 'ghp_')" "the gate never echoes the credential"

# --- the source lives under work/artifacts/, so the audit's scans and a forget reach it
outside="$SB/page.html"
printf '<p>hi</p>\n' > "$outside"
out="$(run_preflight artifact "$outside")"
assert_eq location "$(printf '%s' "$out" | jq -r '.findings[0].rule')" "a page outside work/artifacts/ is stopped"
out="$(run_preflight artifact "$WORK/artifacts/missing.html")"
assert_eq unreadable "$(printf '%s' "$out" | jq -r '.findings[0].rule')" "a missing page is never a pass"

# --- a scan grep cannot run is a finding, never a clean page (stub fails the scans only)
mkdir -p "$SB/bin"
cat > "$SB/bin/grep" <<EOF
#!/usr/bin/env bash
case "\$1" in (-nE|-niE) exit 2;; esac
exec $(command -v grep) "\$@"
EOF
chmod +x "$SB/bin/grep"
printf '<p>hi</p>\n' > "$page"
out="$(PATH="$SB/bin:$PATH" run_preflight artifact "$page")"
assert_eq false "$(printf '%s' "$out" | jq -r '.ok')" "a failed scan stops the page"
assert_contains "scan_failed:remote_load" "$(printf '%s' "$out" | jq -r '[.findings[].rule] | join(" ")')" "the failed scan is named"

# --- the audit: past Private needs the owner's message, handled and not declined
audit_status() {
  PA_SKIP_STRUCTURE=1 HOME="$SB" WORK_DIR="$WORK" TZ=UTC bash "$PREFLIGHT" audit 2>/dev/null \
    | jq -r --arg k "$1" '.checks[] | select(.id=="artifact_visibility") | .[$k]'
}
assert_eq ok "$(audit_status status)" "no ledger yet is green"

ts="$(now_iso)"
{
  printf '%s msg=M1 intent=artifact action=written tasks=-\n' "$ts"
  printf '%s msg=M2 intent=other action=declined tasks=-\n' "$ts"
} > "$WORK/INBOX.log"
{
  printf '%s artifact=A1 action=published visibility=private asked=-\n' "$ts"
  printf '%s artifact=A1 action=visibility visibility=public asked=M1\n' "$ts"
  printf '%s artifact=A2 action=published visibility=public asked=direct\n' "$ts"
  printf '%s artifact=A1 action=visibility visibility=private asked=-\n' "$ts"
} > "$WORK/ARTIFACTS.log"
assert_eq warn "$(audit_status status)" "past Private on the owner's word is no pass while sharing is never"
assert_contains "A1, A2" "$(audit_status detail)" "both shared artifacts are named"

sed -i.bak 's/^- artifact_sharing: .*/- artifact_sharing: confirm/' "$WORK/CONFIG.md" && rm -f "$WORK/CONFIG.md.bak"
assert_eq ok "$(audit_status status)" "at confirm, the owner's request or the direct session is green"

printf '%s artifact=A3 action=visibility visibility=public asked=-\n' "$ts" >> "$WORK/ARTIFACTS.log"
printf '%s artifact=A4 action=published visibility=link asked=M2\n' "$ts" >> "$WORK/ARTIFACTS.log"
printf '%s artifact=A5 action=published visibility=public asked=M9\n' "$ts" >> "$WORK/ARTIFACTS.log"
printf 'garbage line\n' >> "$WORK/ARTIFACTS.log"
assert_eq fail "$(audit_status status)" "past Private without an owner request fails"
detail="$(audit_status detail)"
assert_contains "A3" "$detail" "no request on record is named"
assert_contains "A4" "$detail" "a declined message is no request"
assert_contains "A5" "$detail" "a message missing from the ledger is no request"
assert_contains "line 8 unparseable" "$detail" "an unparseable ledger line is never a pass"
assert_eq 0 "$(printf '%s' "$detail" | grep -c 'A1\|A2')" "proven lines are not named"

# --- the verifier knows the key and its two values
verify_cfg() { HOME="$SB" WORK_DIR="$WORK" bash "$VERIFY" --config 2>/dev/null | grep -c "$1"; }
assert_eq 0 "$(verify_cfg 'artifact_sharing')" "a valid artifact_sharing passes silently"
sed -i.bak 's/^- artifact_sharing: .*/- artifact_sharing: always/' "$WORK/CONFIG.md" && rm -f "$WORK/CONFIG.md.bak"
assert_eq 1 "$(verify_cfg 'FAIL enum_artifact_sharing')" "an unknown artifact_sharing value fails"

exit $FAILURES
