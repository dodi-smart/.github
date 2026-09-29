#!/usr/bin/env bash
# Lint a pull request's commit messages with the commitlint CLI, no Docker.
#
# The Docker action this replaces cannot run on the self-hosted fleet: the runner
# is itself a container on the host's daemon, so the workspace it mounts into the
# action does not exist on the host and the action sees no config and no commits.
#
# The messages come from the API, so no history is cloned. The repo's config is
# copied into the tool prefix, because commitlint resolves `extends` relative to
# the config file, and the prefix is where the packages are.
#
# Env: CONFIG (path in the checkout), REPO, NUMBER, GH_TOKEN, PREFIX,
#      HERE (this directory). Test hooks: COMMITLINT (the binary to run),
#      SKIP_INSTALL=true.
set -euo pipefail

: "${REPO:?}" "${NUMBER:?}" "${PREFIX:?}" "${HERE:?}"
config="${CONFIG:-.commitlintrc.json}"

mkdir -p "$PREFIX"
if [ -f "$config" ]; then
  cp "$config" "$PREFIX/$(basename "$config")"
  cfg="$PREFIX/$(basename "$config")"
else
  echo "::notice::$config not found, linting against @commitlint/config-conventional"
  cfg="$PREFIX/.commitlintrc.json"
  printf '{"extends":["@commitlint/config-conventional"]}\n' > "$cfg"
fi

if [ "${SKIP_INSTALL:-false}" != true ]; then
  cp "$HERE/package.json" "$HERE/package-lock.json" "$PREFIX/"
  (cd "$PREFIX" && npm ci --ignore-scripts --no-audit --no-fund >/dev/null)
  # A JSON config may extend a package the pinned set does not carry.
  extra=$(jq -r '(.extends // []) | if type == "string" then [.] else . end | .[]
                 | select(startswith(".") | not)
                 | select(. != "@commitlint/config-conventional")' "$cfg" 2>/dev/null || true)
  if [ -n "$extra" ]; then
    # shellcheck disable=SC2086  # one package spec per word
    (cd "$PREFIX" && npm install --no-save --ignore-scripts --no-audit --no-fund $extra >/dev/null)
  fi
fi
lint="${COMMITLINT:-$PREFIX/node_modules/.bin/commitlint}"

failed=0
while IFS=$'\t' read -r sha msg64; do
  msg=$(printf '%s' "$msg64" | base64 -d)
  if out=$(printf '%s\n' "$msg" | "$lint" --config "$cfg" 2>&1); then
    echo "ok   ${sha:0:7} ${msg%%$'\n'*}"
  else
    failed=1
    echo "::error title=Commit message::${sha:0:7} ${msg%%$'\n'*}"
    printf '%s\n' "$out"
  fi
done < <(gh api "/repos/$REPO/pulls/$NUMBER/commits?per_page=100" --paginate \
           --jq '.[] | [.sha, (.commit.message | @base64)] | @tsv')
exit "$failed"
