---
name: Bug report
about: Report incorrect behavior in pkf or the schema
labels: bug
---

## What happened

A description of the buggy behavior. If `pkf run` produced wrong
output or hit cache when it shouldn't have, paste the relevant lines.

## Reproduction

A minimal `Taskfile.pkl` (or a link to one), plus the `pkf` command
that triggered the bug. The smaller, the better.

```pkl
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@<ver>#/Taskfile.pkl"

# ...
```

```sh
pkf run <task>
```

## Expected vs actual

What you expected pkfire to do, and what it actually did.

## Environment

- `pkf version`:
- OS and arch:
- Pkl CLI version (`pkl --version`):
- Installed via: Go / Nix / GitHub Action / built from source

## Action key (if relevant)

If this is a caching question, paste `pkf run --print-hash <task>`
output for the affected task — that almost always points at the real
cause.
