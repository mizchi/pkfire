<!--
Thanks for the patch. The Test workflow runs `examples/dogfood/Taskfile.pkl ci`
on every PR; if that's green and the items below are addressed, this is
ready for review.
-->

## What changed

A short description of the change.

## Why

The problem this solves, or the use case it enables. Link any related
issue.

## Test coverage

- [ ] `pkf run -f examples/dogfood/Taskfile.pkl ci` passes locally.
- [ ] If the schema changed, `pkl test --project-dir pkl` passes.
- [ ] If the runner changed, new behavior has a Go test exercising it.
- [ ] If the public Pkl surface changed (a new field, a new constraint,
      a renamed property), I bumped `pkl/PklProject`'s `package.version`
      and ran `scripts/bump-version.sh` to refresh references.

## Notes for reviewers

Anything reviewers should look at first or that's intentionally left
out of scope.
