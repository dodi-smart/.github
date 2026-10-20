#!/usr/bin/env bash
# Assert the decisions distribute.sh makes after a build: which APKs count, what
# is uploaded, whether Firebase is called, what its release notes say, and that
# no secret is ever an argument. `gh` and `npx` are fakes on PATH that record
# every call, so nothing here needs a network or a release.
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/distribute.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/android-distribute-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0

ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

# --- fakes ---------------------------------------------------------------------
mkdir "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# One line per call: the name, then every argument, tab-separated. Whether the
# token reached it by environment is recorded on a line of its own.
{ printf 'gh'; printf '\t%s' "$@"; printf '\n'; } >> "$CALLS"
printf 'ENV\tGH_TOKEN=%s\n' "${GH_TOKEN:+set}" >> "$CALLS"
case "$1 $2" in
  "release upload") [ -z "${FAKE_UPLOAD_FAIL:-}" ] || { echo "HTTP 403" >&2; exit 1; } ;;
  "release view")
    [ -z "${FAKE_VIEW_FAIL:-}" ] || { echo "HTTP 404" >&2; exit 1; }
    [ ! -f "${FAKE_BODY_FILE:-}" ] || cat "$FAKE_BODY_FILE" ;;
esac
FAKE
cat > "$ROOT/bin/npx" <<'FAKE'
#!/usr/bin/env bash
{ printf 'npx'; printf '\t%s' "$@"; printf '\n'; } >> "$CALLS"
printf 'ENV\tGOOGLE_APPLICATION_CREDENTIALS=%s\n' "${GOOGLE_APPLICATION_CREDENTIALS:-}" >> "$CALLS"
# The notes file is removed when the script exits, so keep a copy to read.
prev=""
for a in "$@"; do
  [ "$prev" != "--release-notes-file" ] || cp "$a" "$NOTES_SEEN"
  prev="$a"
done
[ -z "${FAKE_NPX_FAIL:-}" ] || { echo "firebase failed" >&2; exit 1; }
FAKE
chmod +x "$ROOT/bin/gh" "$ROOT/bin/npx"

# A credentials file with a recognisable body, to prove it never reaches argv.
CREDS="$ROOT/creds.json"
printf '{"private_key":"KEY-BODY-MARKER"}' > "$CREDS"
TOKEN="ghs_TOKEN-MARKER-0123456789"

# --- harness -------------------------------------------------------------------
# new_case <name>: a clean workspace and fresh logs. APKs are made with apk <path>.
new_case() {
  CASE="$ROOT/case-$1"; mkdir -p "$CASE/ws"
  CALLS="$CASE/calls"; : > "$CALLS"
  NOTES_SEEN="$CASE/notes-seen"
  OUT="$CASE/out"
  export CALLS NOTES_SEEN
  unset FAKE_UPLOAD_FAIL FAKE_VIEW_FAIL FAKE_NPX_FAIL
  export FAKE_BODY_FILE="$CASE/body"
  rm -f "$FAKE_BODY_FILE"
  ENVV=( TAG=v1.2.3 REPO=org/repo GH_TOKEN="$TOKEN" )
}
apk() { mkdir -p "$CASE/ws/$(dirname "$1")"; : > "$CASE/ws/$1"; }
body() { printf '%s' "$1" > "$FAKE_BODY_FILE"; }

# run [VAR=value ...]: the script in the case's workspace. Sets RC; output in $OUT.
run() {
  ( cd "$CASE/ws" && env -u TAG -u REPO -u APK_GLOB -u FIREBASE_APP_ID -u FIREBASE_GROUPS -u FIREBASE_TOOLS_VERSION \
      -u CREDENTIALS_FILE -u GITHUB_REPOSITORY -u NOTES_MAX \
      PATH="$ROOT/bin:$PATH" RUNNER_TEMP="$CASE" \
      GITHUB_SERVER_URL=https://example.invalid "${ENVV[@]}" "$@" "$SCRIPT" ) > "$OUT" 2>&1
  RC=$?
}

called()    { grep -c "^$1"$'\t' "$CALLS" || true; }
expect_rc() { # <rc> <label>
  [ "$RC" = "$1" ] && ok "$2" || { bad "$2" "exit $RC, wanted $1"; sed 's/^/       | /' "$OUT"; }
}
expect_out() { # <label> <fixed string in the output>
  grep -qF -- "$2" "$OUT" && ok "$1" || { bad "$1" "output lacks: $2"; sed 's/^/       | /' "$OUT"; }
}
expect_calls() { # <label> <gh upload count> <npx count>
  local u d
  u="$(grep -c $'^gh\trelease\tupload\t' "$CALLS" || true)"; d="$(called npx)"
  [ "$u" = "$2" ] && [ "$d" = "$3" ] && ok "$1" || bad "$1" "uploads $u (wanted $2), distributions $d (wanted $3)"
}

# --- no match, unsigned ---------------------------------------------------------
echo "which APKs count"
new_case none
run
expect_rc 1 "zero matches fails"
expect_out "  and says what it looked for" "no APK matches apk-glob"
expect_calls "  and uploads nothing" 0 0

new_case unsigned-only
apk app/build/outputs/apk/release/app-release-unsigned.apk
run
expect_rc 1 "only unsigned APKs fail"
expect_out "  and names the cause" "did not apply the injected signing"
expect_calls "  and uploads nothing" 0 0

new_case unsigned-and-signed
apk app/build/outputs/apk/release/app-release-unsigned.apk
apk app/build/outputs/apk/release/app-release.apk
run
expect_rc 0 "an unsigned APK beside a signed one is ignored"
grep -q $'^gh\trelease\tupload\tv1.2.3\tapp/build/outputs/apk/release/app-release.apk\t--clobber\t--repo\torg/repo$' "$CALLS" \
  && ok "  and only the signed one is uploaded, with --clobber" || bad "  and only the signed one is uploaded" "$(grep upload "$CALLS")"

new_case root-level
apk build/outputs/apk/release/app-release.apk
run
expect_rc 0 "the default glob matches a module at the repository root"

new_case dup-names
apk a/build/outputs/apk/release/app-release.apk
apk b/build/outputs/apk/release/app-release.apk
run
expect_rc 1 "two APKs with one file name fail"
expect_out "  and says why" "would overwrite each other"
expect_calls "  and uploads nothing" 0 0

new_case custom-globs
apk out/one.apk
apk other/two.apk
run APK_GLOB=$'  out/*.apk  \n\nother/*.apk\n'
expect_rc 0 "several globs, with blank lines and padding, are all read"
grep -qE $'^gh\trelease\tupload\tv1.2.3\tother/two.apk\tout/one.apk\t--clobber' "$CALLS" \
  && ok "  and both files are uploaded, sorted" || bad "  and both files are uploaded" "$(grep upload "$CALLS")"

# --- without Firebase ------------------------------------------------------------
echo "no Firebase app id"
new_case no-app
apk app/build/outputs/apk/release/app-release.apk
run
expect_rc 0 "an empty app id succeeds"
expect_calls "  attaches the APK and calls no Firebase" 1 0

new_case upload-fails
apk app/build/outputs/apk/release/app-release.apk
run FAKE_UPLOAD_FAIL=1 FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=1.2.3 CREDENTIALS_FILE="$CREDS"
expect_rc 1 "a failed upload fails the job"
expect_calls "  and nothing is distributed after it" 1 0

# --- with Firebase ----------------------------------------------------------------
echo "distribution"
new_case go
apk app/build/outputs/apk/release/app-release.apk
body $'## 1.2.3\n\n* a thing\n'
run FIREBASE_APP_ID=1:123:android:abc FIREBASE_GROUPS=' qa, internal ' FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CREDS"
expect_rc 0 "one APK and an app id distribute"
expect_calls "  upload once, distribute once" 1 1
grep -q $'^npx\t--yes\tfirebase-tools@15.32.1\tappdistribution:distribute\tapp/build/outputs/apk/release/app-release.apk\t--app\t1:123:android:abc\t--release-notes-file\t' "$CALLS" \
  && ok "  with the pinned version, the app and the notes file" || bad "  npx arguments" "$(grep '^npx' "$CALLS")"
grep -q $'\t--groups\tqa,internal$' "$CALLS" && ok "  groups are passed with the spaces removed" || bad "  groups" "$(grep '^npx' "$CALLS")"
grep -q "^ENV"$'\t'"GOOGLE_APPLICATION_CREDENTIALS=$CREDS\$" "$CALLS" \
  && ok "  and the credentials arrive by environment" || bad "  credentials env" "$(grep GOOGLE "$CALLS")"
grep -q 'a thing' "$NOTES_SEEN" && ok "  the notes are the release body" || bad "  notes" "$(cat "$NOTES_SEEN" 2>/dev/null)"
[ "$(grep -n 'release.upload' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n '^npx' "$CALLS" | head -1 | cut -d: -f1)" ] \
  && ok "  and the upload comes before the distribution" || bad "  order" "$(cut -c1-40 "$CALLS")"
compgen -G "$CASE/android-distribute.*" > /dev/null \
  && bad "  and removes its scratch directory" "left behind" || ok "  and removes its scratch directory"

new_case no-groups
apk app/build/outputs/apk/release/app-release.apk
run FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CREDS"
grep -q -- '--groups' "$CALLS" && bad "an empty group list passes no --groups" "$(grep '^npx' "$CALLS")" || ok "an empty group list passes no --groups"

new_case empty-body
apk app/build/outputs/apk/release/app-release.apk
body ''
run FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CREDS"
expect_rc 0 "an empty release body still distributes"
grep -qx 'Release v1.2.3' "$NOTES_SEEN" && ok "  with fallback notes naming the tag" || bad "  fallback notes" "$(cat "$NOTES_SEEN" 2>/dev/null)"

new_case blank-body
apk app/build/outputs/apk/release/app-release.apk
body $' \n\n  \n'
run FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CREDS"
grep -qx 'Release v1.2.3' "$NOTES_SEEN" && ok "a whitespace-only body takes the fallback too" || bad "  fallback notes" "$(cat "$NOTES_SEEN" 2>/dev/null)"

new_case view-fails
apk app/build/outputs/apk/release/app-release.apk
run FAKE_VIEW_FAIL=1 FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CREDS"
expect_rc 0 "an unreadable release body does not stop the distribution"
expect_out "  but warns" "could not read the release notes"
grep -qx 'Release v1.2.3' "$NOTES_SEEN" && ok "  and uses the fallback" || bad "  fallback notes" "$(cat "$NOTES_SEEN" 2>/dev/null)"

new_case long-body
apk app/build/outputs/apk/release/app-release.apk
# 'é' is two bytes, so a byte cut at 100 lands inside one when the run is odd.
{ printf 'x'; for _ in $(seq 1 200); do printf 'é'; done; } > "$FAKE_BODY_FILE"
run NOTES_MAX=100 FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CREDS"
expect_rc 0 "an over-long body still distributes"
head_part="$(sed -n '1p' "$NOTES_SEEN")"
[ "$(printf '%s' "$head_part" | wc -c)" -le 100 ] && ok "  cut to the byte cap" || bad "  cap" "$(printf '%s' "$head_part" | wc -c) bytes"
if command -v iconv > /dev/null 2>&1; then
  iconv -f UTF-8 -t UTF-8 "$NOTES_SEEN" > /dev/null 2>&1 && ok "  without splitting a multibyte character" || bad "  utf-8" "invalid sequence in notes"
fi
grep -q 'truncated' "$NOTES_SEEN" && grep -q 'releases/tag/v1.2.3' "$NOTES_SEEN" \
  && ok "  and points to the full text" || bad "  truncation note" "$(tail -3 "$NOTES_SEEN")"

new_case exact-cap
apk app/build/outputs/apk/release/app-release.apk
printf '%s' "$(head -c 100 /dev/zero | tr '\0' 'a')" > "$FAKE_BODY_FILE"
run NOTES_MAX=100 FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CREDS"
grep -q 'truncated' "$NOTES_SEEN" && bad "a body exactly at the cap is left whole" "was truncated" || ok "a body exactly at the cap is left whole"

new_case several
apk app/build/outputs/apk/release/app-release.apk
apk other/build/outputs/apk/release/other-release.apk
run FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CREDS"
expect_rc 1 "several APKs with an app id fail the distribution"
expect_calls "  after attaching both" 1 0
expect_out "  and say which to narrow" "Narrow apk-glob"
grep -q $'upload\tv1.2.3\tapp/build/outputs/apk/release/app-release.apk\tother/build/outputs/apk/release/other-release.apk\t' "$CALLS" \
  && ok "  both were uploaded in one call" || bad "  upload" "$(grep upload "$CALLS")"

new_case several-no-app
apk app/build/outputs/apk/release/app-release.apk
apk other/build/outputs/apk/release/other-release.apk
run
expect_rc 0 "several APKs with no app id are simply attached"
expect_calls "  both in one upload" 1 0

new_case firebase-fails
apk app/build/outputs/apk/release/app-release.apk
run FAKE_NPX_FAIL=1 FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CREDS"
expect_rc 1 "a failed distribution fails the job"

# --- inputs that must be right before anything is uploaded -------------------------
echo "refusals"
for v in latest 15 15.32 '^15.32.1' 15.32.1-beta; do
  new_case "ver-$v"
  apk app/build/outputs/apk/release/app-release.apk
  run FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION="$v" CREDENTIALS_FILE="$CREDS"
  { [ "$RC" = 1 ] && [ "$(grep -c "^gh" "$CALLS")" = 0 ]; } && ok "firebase-tools-version '$v' is refused before any upload" || bad "version '$v'" "exit $RC, calls: $(cut -c1-30 "$CALLS" | tr '\n' ' ')"
done

new_case no-creds
apk app/build/outputs/apk/release/app-release.apk
run FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1
expect_rc 1 "a missing credentials-file is refused"
expect_calls "  before anything is uploaded" 0 0

new_case empty-creds
apk app/build/outputs/apk/release/app-release.apk
: > "$CASE/empty.json"
run FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CASE/empty.json"
expect_rc 1 "an empty credentials file is refused"

new_case no-tag
apk app/build/outputs/apk/release/app-release.apk
ENVV=( REPO=org/repo GH_TOKEN="$TOKEN" )
run
expect_rc 1 "a missing tag is refused"

new_case no-creds-needed-without-app
apk app/build/outputs/apk/release/app-release.apk
run FIREBASE_TOOLS_VERSION=latest
expect_rc 0 "the version and credentials are ignored when nothing is distributed"

# --- secrets --------------------------------------------------------------------------
echo "secrets"
new_case secrets
apk app/build/outputs/apk/release/app-release.apk
body $'* a change\n'
run FIREBASE_APP_ID=app FIREBASE_TOOLS_VERSION=15.32.1 CREDENTIALS_FILE="$CREDS"
expect_rc 0 "a full run for the checks below"
if grep -qF -e "$TOKEN" -e 'KEY-BODY-MARKER' "$CALLS"; then
  bad "no secret appears in any recorded argument" "$(grep -F -e "$TOKEN" -e KEY-BODY-MARKER "$CALLS")"
else
  ok "no secret appears in any recorded argument"
fi
if grep -qF -e "$TOKEN" -e 'KEY-BODY-MARKER' "$OUT"; then
  bad "no secret appears in the output" "printed"
else
  ok "no secret appears in the output"
fi
[ "$(grep -c $'^ENV\tGH_TOKEN=set$' "$CALLS")" -ge 2 ] && ok "gh gets the token from its environment" || bad "gh token env" "$(grep '^ENV' "$CALLS")"
if grep '^npx' "$CALLS" | grep -qF "$CREDS"; then bad "the credentials path is not an npx argument" "$(grep '^npx' "$CALLS")"; else ok "the credentials path is not an npx argument"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
