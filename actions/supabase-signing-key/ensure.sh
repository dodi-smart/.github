#!/usr/bin/env bash
# Give a clean checkout the local JWT signing key its config names.
#
# A repo may point `[auth] signing_keys_path` in supabase/config.toml at a
# git-ignored file, generated once per developer checkout. On a clean CI
# checkout that file is missing, and the CLI refuses to load the config at all:
# `db start` and `db schema declarative sync` both fail before they do anything.
# This writes a throwaway ES256 development key there. It is never imported
# anywhere and dies with the runner.
#
# Does nothing when the config sets no path, names it through env(), or the
# file already exists. Only the local [auth] section counts, never
# [remotes.*.auth]. The path is relative to supabase/, as the CLI reads it.
set -euo pipefail

config=supabase/config.toml
[ -f "$config" ] || { echo "no $config, nothing to prepare"; exit 0; }

path="$(awk '
  /^[[:space:]]*\[/ { sec = $0; gsub(/[[:space:]]/, "", sec); next }
  sec == "[auth]" && /^[[:space:]]*signing_keys_path[[:space:]]*=/ {
    sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, ""); gsub(/^"|"$/, ""); print; exit
  }' "$config")"

if [ -z "$path" ]; then echo "config.toml sets no signing_keys_path"; exit 0; fi
case "$path" in env\(*) echo "signing_keys_path comes from $path; left to the caller"; exit 0 ;; esac

case "$path" in /*) file="$path" ;; *) file="supabase/${path#./}" ;; esac
if [ -s "$file" ]; then echo "$file exists"; exit 0; fi

mkdir -p "$(dirname "$file")"
umask 077
echo '[]' > "$file"
supabase gen signing-key --append
echo "::notice::wrote a throwaway development signing key to $file, which config.toml names and the checkout lacks"
