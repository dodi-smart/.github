# dodi-smart

We build and run software for other people's businesses. Connected devices and
the platforms behind them, mobile apps, and the web front ends that tie them
together.

Most of what we do lives in private repositories, because it belongs to the
people who commissioned it. What is public is how we work.

## What we publish

- **[`.github`](https://github.com/dodi-smart/.github)** - the shared CI standard
  for the org. Reusable workflows, composite actions, and the Renovate preset
  every repo extends. A repo adopting it replaces its hand-written pipeline with
  a caller file of about twenty lines.

Everything here is generic by design. No product names, no hostnames, no
customer detail.

## How we work

Automation is governed rather than sprinkled around. Agents run behind a
deterministic gate with a kill switch that is checked first, always, in every
workflow. Nothing automated merges anything. Runners are chosen by capability
rather than by hardware, and the choice is validated against the live fleet, so a
selector that matches nothing is reported instead of quietly falling back.

The reasoning behind each rule is written next to the rule, so a reader with
nothing but the repository can change it safely.

## Contact

Open an issue on a public repository, or reach us through the address on the
organization profile.
