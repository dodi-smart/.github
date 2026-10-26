#!/usr/bin/env bash
# The lanes of one pr-checks run: a lane is one leg of the `lanes` matrix job,
# listed only when it has work, so a pull request's checks list shows no
# skipped rows. Each rule below is what a job-level `if:` used to say; test.sh
# holds them as a table of inputs against the lanes they give.
#
#   docs-only    only `checks` (light, no phases), and only to carry commitlint
#                or zavet: the commit messages and the knowledge layer are not
#                the files, and neither is worth a heavy runner
#   single-job   `all` (heavy): every phase, hk, dependency-check, React Doctor,
#                commitlint, the coverage upload
#   split        `checks` (light: install, lint, design-lint, typecheck, hk,
#                dependency-check, React Doctor, commitlint), `test` (heavy,
#                only with a test command; the coverage upload) and `build`
#                (heavy, only with a build command)
#   iOS          on the hosted Mac, never on a docs-only change, only for kmm,
#                flutter and xcode with a non-empty `ios` and the label
#   zavet        folded into `checks` or `all` when it can reuse their toolchain
#                and install (`zavet-stack` none or the stack, no `zavet-install`),
#                else its own light `Zavet Check` lane. A lane with no install
#                phase (that one, or a docs-only `checks`) has no env file to
#                hand zavet, so zavet sets itself up there
#
# In (env; a boolean is true only as the string `true`):
#   STACK, SINGLE_JOB, DOCS_ONLY, HAS_TEST, HAS_BUILD, LIGHT and HEAVY (runner
#   selectors as JSON, from pick-runner), HK, DEPENDENCY_CHECK, COMMITLINT (on,
#   and the event is a pull request), COVERAGE (none | vitest | kover | lcov),
#   ZAVET, ZAVET_STACK, ZAVET_INSTALL, REACT_DOCTOR (on, and its paths changed),
#   IOS (the raw input), IOS_LABELLED
# Out ($GITHUB_OUTPUT): `lanes`, a compact JSON array of
#   {id, name, runs_on, phases, hk, zavet, react_doctor, commitlint,
#    dependency_check, coverage_upload}
# and `coverage`, true when a lane uploads a coverage report.
set -euo pipefail

lanes="$(jq -cn '
  def on($k): $ENV[$k] == "true";
  def str($k; $default): $ENV[$k] // $default;
  def lane($id; $name; $runs_on; $phases):
    { id: $id, name: $name, runs_on: $runs_on, phases: $phases, hk: false, zavet: false,
      react_doctor: false, commitlint: false, dependency_check: false, coverage_upload: false };
  str("STACK"; "") as $stack | str("LIGHT"; "") as $light | str("HEAVY"; "") as $heavy
  | (str("COVERAGE"; "none") != "none") as $cov
  | on("HK") as $hk | on("DEPENDENCY_CHECK") as $dep | on("COMMITLINT") as $commitlint | on("ZAVET") as $zavet
  | {hk: $hk, dependency_check: $dep, commitlint: $commitlint, react_doctor: on("REACT_DOCTOR")} as $opt
  | ($zavet and (str("ZAVET_STACK"; "none") | IN("none", $stack)) and str("ZAVET_INSTALL"; "") == "") as $fold
  | (if on("DOCS_ONLY") then
       if $commitlint or $zavet then
         [lane("checks"; "checks"; $light; []) + {commitlint: $commitlint, zavet: $zavet}]
       else [] end
     else
       (if on("SINGLE_JOB") then
          [lane("all"; "all"; $heavy; ["install", "lint", "design-lint", "typecheck", "test", "build"])
           + $opt + {coverage_upload: $cov}]
        else
          [lane("checks"; "checks"; $light; ["install", "lint", "design-lint", "typecheck"])
           + $opt]
          + (if on("HAS_TEST") then [lane("test"; "test"; $heavy; ["install", "test"]) + {coverage_upload: $cov}] else [] end)
          + (if on("HAS_BUILD") then [lane("build"; "build"; $heavy; ["install", "build"])] else [] end)
        end)
       | (if $fold then .[0].zavet = true
          elif $zavet then . + [lane("zavet"; "Zavet Check"; $light; []) + {zavet: true}]
          else . end)
       | . + (if str("IOS"; "") != "" and ($stack | IN("kmm", "flutter", "xcode")) and on("IOS_LABELLED")
              then [lane("ios"; "iOS"; ("macos-latest" | tojson); ["install", "ios"])] else [] end)
     end)
  | (map(select(.runs_on == "")) | first) as $none
  | if $none then error("no runner was picked for the \($none.name) lane") else . end
  ')"

coverage="$(jq 'any(.[]; .coverage_upload)' <<<"$lanes")"
echo "lanes: $(jq -r 'map(.name) | if length == 0 then "none" else join(", ") end' <<<"$lanes")"
{
  echo "lanes=$lanes"
  echo "coverage=$coverage"
} >> "${GITHUB_OUTPUT:-/dev/null}"
