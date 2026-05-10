// Reference Cloudflare Worker for pkfire's remote cache.
//
// Protocol (matches what `pkf` will speak in phase 6.x):
//
//   GET  /v1/cas/<hex64>   → 200 + tar.zst body | 404
//   HEAD /v1/cas/<hex64>   → 200 | 404
//   PUT  /v1/cas/<hex64>   → 201 | 200 (already present)
//
//   Authorization: Bearer <AUTH_TOKEN>  (when AUTH_TOKEN secret is set)

interface Env {
  CACHE: R2Bucket;
  AUTH_TOKEN?: string;
  /** TTL in days; entries older than this at GC time are removed. */
  CACHE_TTL_DAYS?: string;
}

const CAS_RE = /^\/v1\/cas\/([0-9a-f]{64})$/;

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (env.AUTH_TOKEN) {
      const expected = `Bearer ${env.AUTH_TOKEN}`;
      if (req.headers.get("Authorization") !== expected) {
        return new Response("unauthorized\n", { status: 401 });
      }
    }

    const { pathname } = new URL(req.url);
    const m = CAS_RE.exec(pathname);
    if (!m) {
      return new Response("not found\n", { status: 404 });
    }
    const key = m[1];

    switch (req.method) {
      case "GET": {
        const obj = await env.CACHE.get(key);
        if (!obj) return new Response(null, { status: 404 });
        return new Response(obj.body, {
          headers: {
            "Content-Type": "application/zstd",
            "ETag": obj.httpEtag,
          },
        });
      }
      case "HEAD": {
        const head = await env.CACHE.head(key);
        return new Response(null, { status: head ? 200 : 404 });
      }
      case "PUT": {
        if (!req.body) {
          return new Response("missing body\n", { status: 400 });
        }
        const existed = await env.CACHE.head(key);
        await env.CACHE.put(key, req.body);
        return new Response(null, { status: existed ? 200 : 201 });
      }
      default:
        return new Response("method not allowed\n", {
          status: 405,
          headers: { Allow: "GET, HEAD, PUT" },
        });
    }
  },

  // GC entries older than CACHE_TTL_DAYS. Triggered by the cron in
  // wrangler.toml. Paginates over R2.list() in 1000-key chunks, batch
  // deletes the stale ones, and logs how many were removed.
  async scheduled(_event: ScheduledController, env: Env, _ctx: ExecutionContext): Promise<void> {
    const ttlDays = Number(env.CACHE_TTL_DAYS ?? "7");
    if (!Number.isFinite(ttlDays) || ttlDays <= 0) {
      console.error(`invalid CACHE_TTL_DAYS=${env.CACHE_TTL_DAYS}; skipping GC`);
      return;
    }
    const cutoff = Date.now() - ttlDays * 24 * 60 * 60 * 1000;
    let cursor: string | undefined;
    let kept = 0;
    let removed = 0;
    do {
      const list = await env.CACHE.list({ cursor, limit: 1000 });
      const stale: string[] = [];
      for (const obj of list.objects) {
        if (obj.uploaded.getTime() < cutoff) {
          stale.push(obj.key);
        } else {
          kept++;
        }
      }
      if (stale.length > 0) {
        await env.CACHE.delete(stale);
        removed += stale.length;
      }
      cursor = list.truncated ? list.cursor : undefined;
    } while (cursor);
    console.log(`pkfire-cache GC: removed=${removed} kept=${kept} ttlDays=${ttlDays}`);
  },
};
