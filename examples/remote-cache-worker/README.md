# pkfire-cache-worker

Reference Cloudflare Worker that backs `pkfire`'s remote cache with R2.
This is the recommended starting point for hosting a remote cache:
deploy it once into your own Cloudflare account, point `pkf` at it, and
your team shares cache hits across machines and CI.

## Protocol

```
GET  /v1/cas/<hex64>          → 200 + tar.zst body | 404
HEAD /v1/cas/<hex64>          → 200 | 404
PUT  /v1/cas/<hex64>          → 201 (or 200 if already present)
                                  body: tar.zst
                                  Content-Type: application/zstd

Authorization: Bearer <AUTH_TOKEN>   (when AUTH_TOKEN secret is set)
```

`<hex64>` is the lowercase BLAKE3 action key (32 bytes / 64 hex chars).

## Deploy

```sh
pnpm install
wrangler r2 bucket create pkfire-cache
wrangler secret put AUTH_TOKEN     # paste a long random string
pnpm deploy
```

Then in any project:

```sh
export PKFIRE_REMOTE_CACHE=https://pkfire-cache.<account>.workers.dev
export PKFIRE_REMOTE_TOKEN=<the same string>
pkf run build
```

## Garbage collection

A daily cron (`0 3 * * *` in `wrangler.toml`) runs the worker's
`scheduled` handler, which deletes every R2 object whose `uploaded`
timestamp is older than `CACHE_TTL_DAYS` (default `7`). Override via
`[vars]` in `wrangler.toml` or with `wrangler secret put CACHE_TTL_DAYS`
if you want a longer or shorter window.

The handler paginates `R2.list()` in 1000-key chunks and batch-deletes
stale entries; one log line is written per run:

```
pkfire-cache GC: removed=42 kept=308 ttlDays=7
```

## Local development

`wrangler dev` runs the worker against a locally-emulated R2 bucket:

```sh
pnpm install
pnpm dev                      # http://localhost:8787
pnpm dev --test-scheduled     # also exposes /__scheduled?cron=...
pnpm smoke                    # PUT/HEAD/GET + GC trigger via curl
```

The smoke script lives at `smoke.sh` and exercises the success and
error paths without auth, then trips the scheduled GC handler when
`--test-scheduled` is enabled. Set `AUTH_TOKEN` in `.dev.vars` if you
want to test the bearer-token path locally.
