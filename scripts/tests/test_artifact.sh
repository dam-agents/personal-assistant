#!/usr/bin/env bash
# The artifact gate must pass a self-contained page and stop one that loads, calls,
# or carries a credential — naming lines, never the text. The audit must judge each
# artifact by its latest ledger line: fail one past Private that no owner artifact
# request at artifact_sharing: confirm proves, and clear once it is narrowed or
# confirmed (docs/privacy.md -> Artifacts).
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
rules() { printf '%s' "$1" | jq -r '[.findings[].rule] | join(" ")'; }

# --- a self-contained page: inline style and script, a data: image, a link to click,
# an in-page fragment, and the owner's text naming network APIs (text, not code)
cat > "$page" <<'EOF'
<!doctype html>
<html><head><style>body{font:14px sans-serif}</style></head>
<body><svg xmlns="http://www.w3.org/2000/svg"><rect id="dot" width="4" height="4"/><use href="#dot"/></svg>
<img src="data:image/png;base64,iVBORw0KGgo="><img src="">
<a href="https://example.com/help">help</a> <a href="#top">top</a>
<p>Fix the WebSocket reconnect; drop XMLHttpRequest</p>
<script>document.body.dataset.ready = "1"; window.location.hash = "#top"; const location_name = "Prague";</script>
</body></html>
EOF
out="$(run_preflight artifact "$page")"
assert_eq artifact "$(printf '%s' "$out" | jq -r '.mode')" "the gate emits its mode"
assert_eq true "$(printf '%s' "$out" | jq -r '.ok')" "a self-contained page passes"
assert_eq "" "$(rules "$out")" "no finding on a self-contained page"
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

# --- the subtler shapes: an SVG script or filter image, a later srcset candidate,
# image-set, setAttribute, JS-escaped slashes, and navigating away with data
cat > "$page" <<'EOF'
<svg><script xlink:href="https://x.example.net/a.js"/></svg>
<svg><filter><feImage href="https://x.example.net/a.png"/></filter></svg>
<img srcset="data:image/png;base64,iVBORw0KGgo= 1x, https://x.example.net/b.png 2x">
<div style="background-image:image-set(&quot;https://x.example.net/a.png&quot; 1x)"></div>
<script>i.setAttribute('src', 'https://x.example.net/p.gif');</script>
<script>img.src = "https:\/\/x.example.net/p.gif";</script>
<script>location = "/?d=" + d;</script>
<script>location.search = "?d=" + d;</script>
EOF
out="$(run_preflight artifact "$page")"
assert_eq "1,2,3,4,5,6" "$(rule_lines "$out" remote_load)" "subtler remote loads named by line"
assert_eq "7,8" "$(rule_lines "$out" network_call)" "navigating away is a network call"

# --- a file beside the page is a load too: the page must be the whole artifact
cat > "$page" <<'EOF'
<script src="app.js"></script>
<link rel="stylesheet" href="style.css">
<svg><use href="sprite.svg#dot"/></svg>
<form action="/submit"></form>
<a href="other.html">fine</a><img src="data:image/png;base64,iVBORw0KGgo="><svg><use href="#dot"/></svg>
EOF
out="$(run_preflight artifact "$page")"
assert_eq "1,2,3,4" "$(rule_lines "$out" local_load)" "loads from beside the page named by line"
assert_eq "" "$(rule_lines "$out" remote_load)" "a local load is not reported as remote"

# --- a NUL byte never turns the page into a pass
printf '<p>a\000b</p>\n<script>fetch("/x")</script>\n' > "$page"
out="$(run_preflight artifact "$page")"
assert_eq false "$(printf '%s' "$out" | jq -r '.ok')" "a page with a NUL byte is still scanned"
assert_eq "2" "$(rule_lines "$out" network_call)" "its lines are still named"

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
assert_eq location "$(rules "$out")" "a page outside work/artifacts/ is stopped"
ln -s "$outside" "$WORK/artifacts/link.html"
out="$(run_preflight artifact "$WORK/artifacts/link.html")"
assert_eq location "$(rules "$out")" "a symlink into work/artifacts/ is stopped"
out="$(run_preflight artifact "$WORK/artifacts/missing.html")"
assert_eq unreadable "$(rules "$out")" "a missing page is never a pass"

# --- a scan grep cannot run is a finding, never a clean page (stub fails the scans only)
mkdir -p "$SB/bin"
cat > "$SB/bin/grep" <<EOF
#!/usr/bin/env bash
case "\$1" in (-na*) exit 2;; esac
exec $(command -v grep) "\$@"
EOF
chmod +x "$SB/bin/grep"
printf '<p>hi</p>\n' > "$page"
out="$(PATH="$SB/bin:$PATH" run_preflight artifact "$page")"
assert_eq false "$(printf '%s' "$out" | jq -r '.ok')" "a failed scan stops the page"
assert_contains "scan_failed:remote_load" "$(rules "$out")" "the failed scan is named"

# --- the audit: past Private needs the owner's artifact request, at confirm
audit_status() {
  PA_SKIP_STRUCTURE=1 HOME="$SB" WORK_DIR="$WORK" TZ=UTC bash "$PREFLIGHT" audit 2>/dev/null \
    | jq -r --arg k "$1" '.checks[] | select(.id=="artifact_visibility") | .[$k]'
}
names() { printf '%s' "$1" | grep -cE "(^|[ ,:])$2([ ,]|\$)"; }
assert_eq ok "$(audit_status status)" "no ledger yet is green"

ts="$(now_iso)"; old="$(day -10)T08:00:00Z"
{
  printf '%s msg=M1 intent=artifact action=written tasks=-\n' "$ts"
  printf '%s msg=M2 intent=other action=declined tasks=-\n' "$ts"
  printf '%s msg=M3 intent=artifact action=failed tasks=-\n' "$ts"
  printf '%s msg=M4 intent=question action=answered tasks=-\n' "$ts"
} > "$WORK/INBOX.log"
{
  printf '%s artifact=A1 action=published visibility=private sharing=never asked=-\n' "$ts"
  printf '%s artifact=A1 action=visibility visibility=public sharing=confirm asked=M1\n' "$ts"
  printf '%s artifact=A2 action=published visibility=public sharing=confirm asked=direct\n' "$ts"
  printf '%s artifact=A1 action=visibility visibility=private sharing=never asked=-\n' "$ts"
} > "$WORK/ARTIFACTS.log"
assert_eq warn "$(audit_status status)" "shared at confirm, still past Private after the owner chose never"
detail="$(audit_status detail)"
assert_eq 1 "$(names "$detail" A2)" "the artifact still shared is named"
assert_eq 0 "$(names "$detail" A1)" "an artifact narrowed back to Private is not"

sed -i.bak 's/^- artifact_sharing: .*/- artifact_sharing: confirm/' "$WORK/CONFIG.md" && rm -f "$WORK/CONFIG.md.bak"
assert_eq ok "$(audit_status status)" "at confirm, the owner's request or the direct session is green"

{
  printf '%s artifact=A3 action=visibility visibility=public sharing=confirm asked=-\n' "$ts"
  printf '%s artifact=A4 action=published visibility=link sharing=confirm asked=M2\n' "$ts"
  printf '%s artifact=A5 action=published visibility=public sharing=confirm asked=M9\n' "$ts"
  printf '%s artifact=A6 action=published visibility=public sharing=confirm asked=M3\n' "$ts"
  printf '%s artifact=A7 action=published visibility=public sharing=confirm asked=M4\n' "$ts"
  printf '%s artifact=A8 action=published visibility=public sharing=never asked=M1\n' "$ts"
  printf '%s artifact=A9 action=published visibility=Private sharing=confirm asked=-\n' "$ts"
  printf 'garbage line\n'
  printf '%s artifact=A10 action=published visibility=public asked=M1\n' "$ts"
} >> "$WORK/ARTIFACTS.log"
assert_eq fail "$(audit_status status)" "past Private without an owner request fails"
detail="$(audit_status detail)"
assert_eq 1 "$(names "$detail" A3)" "no request on record is named"
assert_eq 1 "$(names "$detail" A4)" "a declined message is no request"
assert_eq 1 "$(names "$detail" A5)" "a message missing from the ledger is no request"
assert_eq 1 "$(names "$detail" A6)" "a failed message is no request"
assert_eq 1 "$(names "$detail" A7)" "a message that asked something else is no request"
assert_contains "A8 sharing=never" "$detail" "past Private while sharing was never fails"
assert_contains "line 12 unparseable" "$detail" "an unparseable ledger line is never a pass"
assert_contains "line 13 unparseable" "$detail" "a line without its sharing field is unparseable"
assert_eq 0 "$(names "$detail" A9)" "Private is Private whatever its case"
assert_eq 00 "$(names "$detail" A1)$(names "$detail" A2)" "proven lines are not named"

# --- narrowing or a later confirmation clears an old line; this week's still surfaces once
{
  printf '%s artifact=B1 action=published visibility=public sharing=confirm asked=-\n' "$old"
  printf '%s artifact=B1 action=visibility visibility=private sharing=confirm asked=-\n' "$ts"
  printf '%s artifact=B3 action=published visibility=public sharing=confirm asked=-\n' "$old"
  printf '%s artifact=B3 action=visibility visibility=public sharing=confirm asked=M1\n' "$ts"
} > "$WORK/ARTIFACTS.log"
assert_eq ok "$(audit_status status)" "narrowed or confirmed since, an old unasked line clears"
{
  printf '%s artifact=B2 action=published visibility=public sharing=confirm asked=-\n' "$ts"
  printf '%s artifact=B2 action=visibility visibility=private sharing=confirm asked=-\n' "$ts"
} >> "$WORK/ARTIFACTS.log"
assert_eq fail "$(audit_status status)" "an unasked share narrowed this week still surfaces"
assert_contains "B2 (since changed)" "$(audit_status detail)" "and says it changed since"

# --- the verifier knows the key and its two values
verify_cfg() { HOME="$SB" WORK_DIR="$WORK" bash "$VERIFY" --config 2>/dev/null | grep -c "$1"; }
assert_eq 0 "$(verify_cfg 'artifact_sharing')" "a valid artifact_sharing passes silently"
sed -i.bak 's/^- artifact_sharing: .*/- artifact_sharing: always/' "$WORK/CONFIG.md" && rm -f "$WORK/CONFIG.md.bak"
assert_eq 1 "$(verify_cfg 'FAIL enum_artifact_sharing')" "an unknown artifact_sharing value fails"

exit $FAILURES
