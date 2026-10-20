"""Helpers the Self test steps share.

self-test.yml sets PYTHONPATH to this directory, so a step starts with
`from lib import load, D`. A step's `run:` script may hold no literal
expression opener, because Actions would evaluate it before bash ran. `D`
spells one in two pieces, so a script compares against it without holding one.
"""
import functools

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
