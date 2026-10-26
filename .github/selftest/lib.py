"""Helpers the Self test steps share.

self-test.yml sets PYTHONPATH to this directory, so a step starts with
`from lib import load, D`. A step's `run:` script may hold no literal
expression opener, because Actions would evaluate it before bash ran. `D`
spells one in two pieces, so a script compares against it without holding one.
"""
import functools
import json
import os
import subprocess
import tempfile

import yaml

# An expression opener: compare with D + 'needs.gate.result }}'.
D = '$' + '{{ '

# The first step of every job that runs on a runner (AGENTS.md has why).
REPORT = 'actions/runner-report@'


@functools.cache
def load(path):
    """A workflow or action file, parsed once per script.

    PyYAML reads the bare `on` key as the boolean True (YAML 1.1), so a
    workflow's triggers are doc[True]. Callers must not modify what they get.
    """
    with open(path) as f:
        return yaml.safe_load(f)


def uses(step):
    """The step's `uses:` as a string, empty for a `run:` step."""
    return str(step.get('uses', ''))


def first_step_is_report(job):
    """True when the job starts with actions/runner-report, so a later failure still leaves a report."""
    steps = job.get('steps') or []
    return bool(steps) and REPORT in uses(steps[0])


def checkout_ok(step):
    """True for an actions/checkout step that leaves no token in .git/config."""
    return uses(step).startswith('actions/checkout@') and (step.get('with') or {}).get('persist-credentials') is False


def conjuncts(expr):
    """The terms an `if:` joins with a top-level `&&`, its opener and closer dropped.

    Each term must hold for the job to run, so a job whose terms include X is
    skipped whenever X is false. `&&` binds tighter than `||`, so an expression
    with a top-level `||` is no conjunction and comes back as one whole term.
    """
    e = str(expr).strip()
    if e.startswith(D.strip()) and e.endswith('}}'):
        e = e[len(D.strip()):-2].strip()
    terms, depth, quote, start, i = [], 0, None, 0, 0
    while i < len(e):
        c = e[i]
        if quote:
            quote = None if c == quote else quote
        elif c in '\'"':
            quote = c
        elif c in '()':
            depth += 1 if c == '(' else -1
        elif depth == 0 and e[i:i + 2] in ('&&', '||'):
            if e[i] == '|':
                return [e]
            terms.append(e[start:i].strip())
            start = i + 2
            i += 1
        i += 1
    return terms + [e[start:].strip()]


# A split bun repo with a test and a build command, nothing opted in.
PLAN_DEFAULTS = {
    'STACK': 'bun', 'SINGLE_JOB': 'false', 'DOCS_ONLY': 'false', 'HAS_TEST': 'true', 'HAS_BUILD': 'true',
    'LIGHT': '["self-hosted","Linux","light"]', 'HEAVY': '["self-hosted","Linux","large"]',
    'HK': 'false', 'DEPENDENCY_CHECK': 'false', 'COMMITLINT': 'false', 'COVERAGE': 'none',
    'ZAVET': 'false', 'ZAVET_STACK': 'none', 'ZAVET_INSTALL': '', 'IOS': '@stack', 'IOS_LABELLED': 'false',
}


@functools.cache
def plan(**given):
    """The lanes actions/pr-checks-plan gives a pr-checks run, as a dict by lane id.

    Keywords are plan.sh's env names in lower case (docs_only=True), changing
    PLAN_DEFAULTS. A step asserts what the lanes are, not how plan.sh spells them.
    Cached: callers must not modify what they get.
    """
    env = dict(PLAN_DEFAULTS)
    env.update({k.upper(): str(v).lower() if isinstance(v, bool) else str(v) for k, v in given.items()})
    with tempfile.NamedTemporaryFile('r', suffix='.out') as out:
        subprocess.run(['actions/pr-checks-plan/plan.sh'], check=True, stdout=subprocess.DEVNULL,
                       env={'PATH': os.environ['PATH'], 'GITHUB_OUTPUT': out.name, **env})
        lanes = json.loads(dict(line.split('=', 1) for line in out.read().splitlines())['lanes'])
    return {lane['id']: lane for lane in lanes}
