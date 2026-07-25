# CI

Placeholder (issue #1). No CI pipeline is wired here.

## Why this directory exists

SPEC §10 reserves `ci/` in the repository structure. The gate for every phase (SPEC §19)
is defined as `make` targets, so any future pipeline is a thin wrapper around the same
entry points a developer runs locally — not a second, divergent definition of "passing".

## Current gate: local, not hosted

Per PLAN.md standing rule #2, the CI-equivalent gate is run locally and its command
transcript is pasted into the PR description:

```bash
make lint
make sim-tiny        # plus whichever sim-* targets the change touches
make quartus-map     # for changes that reach synthesis
```

The two toolchains live on different hosts (Verilator in WSL Ubuntu-24.04, Quartus Prime
Pro 26.1 on Windows), and Quartus is neither installable nor licensable on a hosted
runner, so a hosted pipeline could only ever cover the simulation half.

## Out of scope for issue #1

Workflow definitions, runners, caching, and artifact upload. If CI is added later it
belongs in its own issue and must invoke the SPEC §16 targets unmodified.
