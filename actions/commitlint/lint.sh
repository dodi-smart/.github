#!/usr/bin/env bash
# Lint a pull request's commit messages with the commitlint CLI, no Docker.
#
# The Docker action this replaces cannot run on the self-hosted fleet: the runner
# is itself a container on the host's daemon, so the workspace it mounts into the
# action does not exist on the host and the action sees no config and no commits.
#
# The messages and the config both come from the API, so nothing is checked
# out. A sparse checkout would leave the runner's persistent workspace half
# populated for the next job (see AGENTS.md). The config lands in the tool
# prefix, because commitlint resolves `extends` relative to the config file,
# and the prefix is where the packages are.
#
# The config is read at REF, which the action defaults to the pull request's BASE
# commit, not its head. A pull request must not be able to change the rules it is
# linted by, nor make CI install something, so a config change takes effect once
# it has merged. For the same reason `extends` may only name a package the pinned
# set already carries (package.json beside this file, the org preset included):
# nothing is installed on a config's say-so.
#
# Env: CONFIG (path in the repo), REF (commit to read it at), REPO, NUMBER,
# GH_TOKEN, PREFIX, CACHE_HIT (true when the action restored node_modules).
# test.sh sets COMMITLINT and SKIP_INSTALL=true.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${REPO:?}" "${NUMBER:?}" "${PREFIX:?}" "${REF:?}"
config="${CONFIG:-.commitlintrc.json}"
preset="@dodi-smart/commitlint-config"

mkdir -p "$PREFIX"
cfg="$PREFIX/$(basename "$config")"
if ! gh api -H "Accept: application/vnd.github.raw" "/repos/$REPO/contents/$config?ref=$REF" > "$cfg" 2>/dev/null; then
  echo "::notice::$config not found at ${REF:0:7}, linting against the org preset ($preset)"
  cfg="$PREFIX/.commitlintrc.json"
  printf '{"extends":["%s"]}\n' "$preset" > "$cfg"
fi

# Every `extends` entry must be in the pinned set. A relative path would point
# into a repo that is not checked out. Only a JSON config can be read here: any
# other format is left alone, and since nothing is installed for it, an import
# outside the pinned set just fails to resolve.
if jq -e . "$cfg" >/dev/null 2>&1; then
  allowed=$(jq -r '.dependencies | keys[]' "$HERE/package.json")
  while IFS= read -r entry; do
    if ! grep -qxF -- "$entry" <<< "$allowed"; then
      echo "::error title=Commitlint config::$config extends '$entry', which is not in the pinned set." \
           "Allowed: ${allowed//$'\n'/, }." \
           "To allow another package, add it to actions/commitlint/package.json in the shared workflows repo."
      exit 1
    fi
  done < <(jq -r '(.extends? // []) | if type == "string" then [.] else . end | .[] | tostring' "$cfg")
fi

if [ "${SKIP_INSTALL:-false}" != true ]; then
  # The preset is a `file:` dependency, so node_modules holds a symlink to a copy
  # beside package.json. It is needed on a cache hit too.
  cp -R "$HERE/preset" "$PREFIX/"
  if [ "${CACHE_HIT:-}" != true ]; then
    cp "$HERE/package.json" "$HERE/package-lock.json" "$PREFIX/"
    (cd "$PREFIX" && npm ci --prefer-offline --ignore-scripts --no-audit --no-fund >/dev/null)
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
