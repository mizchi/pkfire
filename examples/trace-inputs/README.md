# `pkf trace` fixture

`bundle` reads `conf/settings.ini` but declares only `src/**/*.txt` as
inputs. `pkf trace --check bundle` reports the gap and exits non-zero:

```
pkf: WARN 1 file(s) read but not covered by `inputs`:
pkf:        conf/settings.ini
pkf:      editing one of these will NOT invalidate the cache.
```

`pkf trace --emit bundle` prints the `inputs { ... }` block that would
close it. See [docs/auto-inputs.md](../../docs/auto-inputs.md) for how
the observation works and what it cannot see.
