import { test } from "node:test";
import assert from "node:assert/strict";
import { getToken, listAppraisalsSince, nextUrl, rqlSince, type VautoDeps } from "../src/vauto.ts";

const base = (f: typeof fetch, over: Partial<VautoDeps> = {}): VautoDeps => ({
  fetch: f, outboundCheck: () => ({ ok: true }), baseUrl: "https://vauto.example/api", tokenUrl: "https://vauto.example/oauth/token",
  entityLogicalId: "ent-1", clientId: "cid", clientSecret: "csec", pageSize: 2, timeoutMs: 500, ...over,
});
const script = (routes: (url: string, init: RequestInit, n: number) => Response | Promise<Response>) => { let n = 0; const calls: { url: string; init: RequestInit }[] = []; const f = (async (url: string, init: RequestInit) => { calls.push({ url, init }); return routes(url, init, ++n); }) as unknown as typeof fetch; return { f, calls }; };
const J = (status: number, body: unknown) => new Response(JSON.stringify(body), { status });

test("token: client-credentials form POST with Basic auth; the secret is never in the URL or the query", async () => {
  const { f, calls } = script(() => J(200, { access_token: "T", token_type: "bearer" }));
  const r = await getToken(base(f), 500);
  assert.deepEqual(r, { ok: true, token: "T" });
  assert.equal(calls[0]!.init.method, "POST"); assert.ok(!calls[0]!.url.includes("csec")); assert.equal(String(calls[0]!.init.body), "grant_type=client_credentials&scope=va.appraisal.read");
  assert.equal((calls[0]!.init.headers as Record<string, string>).Authorization, `Basic ${btoa("cid:csec")}`);
});
test("token failures: 401 → VAUTO_AUTH; no access_token → VAUTO_MALFORMED; unconfigured → VAUTO_AUTH without a request", async () => {
  assert.equal((await getToken(base(script(() => J(401, {})).f), 500) as { error: string }).error, "VAUTO_AUTH");
  assert.equal((await getToken(base(script(() => J(200, { nope: 1 })).f), 500) as { error: string }).error, "VAUTO_MALFORMED");
  const s = script(() => J(200, {})); const r = await getToken(base(s.f, { clientSecret: "" }), 500);
  assert.equal((r as { error: string }).error, "VAUTO_AUTH"); assert.equal(s.calls.length, 0);
});
test("list: token, then pages followed through `next` (absolute URL and limit token), items concatenated oldest first", async () => {
  const { f, calls } = script((url, _i, n) => {
    if (n === 1) return J(200, { access_token: "T" });
    if (n === 2) return J(200, { items: [{ id: "1" }, { id: "2" }], next: "https://vauto.example/api/appraisals?entityLogicalId=ent-1&limit=3,2&filter=x" });
    if (n === 3) return J(200, { items: [{ id: "3" }], next: "5,2" });
    return J(200, { items: [], next: null });
  });
  const r = await listAppraisalsSince(base(f), "2026-10-27T00:00:00.000Z", 5000);
  assert.deepEqual(r, { ok: true, items: [{ id: "1" }, { id: "2" }, { id: "3" }], pages: 3 });
  const u1 = new URL(calls[1]!.url);
  assert.equal(u1.searchParams.get("filter"), rqlSince("2026-10-27T00:00:00.000Z")); assert.equal(u1.searchParams.get("limit"), "1,2"); assert.equal(u1.searchParams.get("entityLogicalId"), "ent-1");
  assert.equal((calls[1]!.init.headers as Record<string, string>).Authorization, "Bearer T"); assert.equal(calls[1]!.init.method, "GET");
  assert.equal(new URL(calls[3]!.url).searchParams.get("limit"), "5,2");
  assert.equal(nextUrl("b", "https://x/a?limit=1,2", null), null);
});
test("list: a failing later page returns the items already fetched WITH the error; malformed page likewise", async () => {
  const { f } = script((_u, _i, n) => n === 1 ? J(200, { access_token: "T" }) : n === 2 ? J(200, { items: [{ id: "1" }], next: "3,2" }) : J(503, {}));
  const r = await listAppraisalsSince(base(f), "s", 5000);
  assert.equal(r.ok, false); assert.deepEqual(r.items, [{ id: "1" }]); assert.equal((r as { detail: string }).detail, "page_2:http_503");
  const m = script((_u, _i, n) => n === 1 ? J(200, { access_token: "T" }) : J(200, { items: "nope" }));
  assert.equal((await listAppraisalsSince(base(m.f), "s", 5000) as { error: string }).error, "VAUTO_MALFORMED");
});
test("list: outbound gate refusal makes no request; a hanging page times out; max pages is bounded", async () => {
  const s = script(() => J(200, {}));
  const r = await listAppraisalsSince(base(s.f, { outboundCheck: () => ({ ok: false, reason: "HOST_NOT_ALLOWLISTED" }) }), "s", 500);
  assert.equal((r as { error: string }).error, "HOST_NOT_ALLOWLISTED"); assert.equal(s.calls.length, 0);
  const hang = script((_u, _i, n) => n === 1 ? J(200, { access_token: "T" }) : new Promise<Response>(() => undefined));
  const t = await listAppraisalsSince(base(hang.f, { timeoutMs: 30 }), "s", 200);
  assert.equal((t as { error: string }).error, "VAUTO_TIMEOUT");
  const loop = script((_u, _i, n) => n === 1 ? J(200, { access_token: "T" }) : J(200, { items: [{ id: String(n) }], next: `${n},2` }));
  const l = await listAppraisalsSince(base(loop.f, { maxPages: 3 }), "s", 5000);
  assert.equal(l.ok, false); assert.equal((l as { detail: string }).detail, "max_pages"); assert.equal(l.items.length, 3);
});
