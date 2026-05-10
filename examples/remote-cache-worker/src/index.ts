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
};
