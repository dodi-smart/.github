#!/usr/bin/env bash
# Runs ensure.sh in throwaway project folders against a stub `supabase`. A miss
# here is a red Database lane on every repo whose config names a git-ignored
# key; a false hit overwrites a key the job was given.
# Each check is a condition string eval'd after run() sets STATUS, OUT and FILE.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/supabase-signing-key-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

# The stub appends a key to the file the test names, as the CLI does to the
# configured one, and records that it ran.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/supabase" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "gen signing-key --append" ] || exit 9
echo ran > "$CALLS"
jq -c '. + [{"kty":"EC","alg":"ES256","d":"x"}]' "$KEYFILE" > "$KEYFILE.tmp" && mv "$KEYFILE.tmp" "$KEYFILE"
STUB
chmod +x "$WORK/bin/supabase"

# run CONFIG [KEYFILE]: a project whose config.toml is CONFIG. Sets STATUS, OUT,
# CALLED (yes/no) and KEYS (the key count in KEYFILE, or "none").
run() {
  local proj="$WORK/proj" key="${2:-supabase/signing_keys.json}"
  rm -rf "$proj"; mkdir -p "$proj/supabase"; : > "$WORK/calls"
  [ -n "$1" ] && printf '%s\n' "$1" > "$proj/supabase/config.toml"
  [ -n "${PRESET:-}" ] && printf '%s\n' "$PRESET" > "$proj/$key"
  OUT="$(cd "$proj" && env PATH="$WORK/bin:$PATH" CALLS="$WORK/calls" KEYFILE="$proj/$key" "$HERE/ensure.sh" 2>&1)"
  STATUS=$?
  CALLED=$([ -s "$WORK/calls" ] && echo yes || echo no)
  KEYS=$(jq length "$proj/$key" 2>/dev/null || echo none)
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "status $STATUS called $CALLED keys $KEYS: $OUT"; fi; }

AUTH=$'[auth]\nenabled = true\nsigning_keys_path = "./signing_keys.json"'
run "$AUTH"
check "a missing key file gets a throwaway key" '[ "$STATUS" -eq 0 ] && [ "$CALLED" = yes ] && [ "$KEYS" = 1 ]'
PRESET='[{"kty":"EC","d":"mine"}]' run "$AUTH"
check "an existing key file is left alone" '[ "$CALLED" = no ] && [ "$KEYS" = 1 ] && grep -q exists <<<"$OUT"'
run $'[auth]\nsigning_keys_path = "keys/dev.json" # local only' supabase/keys/dev.json
check "a nested path with a trailing comment is created" '[ "$CALLED" = yes ] && [ "$KEYS" = 1 ]'
run $'[auth]\nenabled = true'
check "no signing_keys_path, nothing to do" '[ "$STATUS" -eq 0 ] && [ "$CALLED" = no ]'
run $'[auth]\nsigning_keys_path = "env(SIGNING_KEYS)"'
check "an env() path is left to the caller" '[ "$STATUS" -eq 0 ] && [ "$CALLED" = no ]'
run $'[auth]\nenabled = true\n[remotes.staging.auth]\nsigning_keys_path = "./remote.json"'
check "a remote section's path does not count" '[ "$CALLED" = no ]'
run $'[auth]\n# signing_keys_path = "./signing_keys.json"'
check "a commented-out path does not count" '[ "$CALLED" = no ]'
run ""
check "no config.toml, nothing to do" '[ "$STATUS" -eq 0 ] && [ "$CALLED" = no ]'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
