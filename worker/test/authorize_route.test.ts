import { test } from "node:test";
import assert from "node:assert/strict";
import { handle } from "../src/index.ts";
import { authorizeRoute, type GateDeps } from "../src/gate_routes.ts";
import { loadConfig } from "../src/config.ts";
import { ENV, FakeConnector, delay, http } from "./fakes.ts";
import type { ReadResult } from "../src/read31.ts";

const cfg = loadConfig(ENV);
const found: ReadResult = { ok: true, missing: false, status: "In-Progress", latencyMs: 5 };
const deps = (db: FakeConnector, read: ReadResult = found, log: Record<string, unknown>[] = []): GateDeps =>
  ({ db, cfg, read31: async () => read, now: () => 1_700_000_000_000, log: (e) => log.push(e) });
const body = { action_key: "package:IID-1:v1", iid: "IID-1", action: "package", caller_run_ref: "run-1", row_status: "In-Progress", triggered_by: "u@x", caller_integration: "zap_texts" };
const grant = { allowed: true, replay: false, attempt_id: "a1", action_id: "g1", deal_id: "d1", deal_version: 1 };

test("happy path: the verified integration, the read status and the read time go to the SQL function; its jsonb is passed through", async () => {
  const db = new FakeConnector(() => [{ r: grant }]);
  const r = await authorizeRoute(deps(db), { integration: "appsheet_31", requestId: "rq", body });
  assert.equal(r.status, 200); assert.equal(r.body.allowed, true); assert.equal(r.body.attempt_id, "a1"); assert.equal(r.body.read_31, "found");
  const c = db.calls[0]!;
  assert.match(c.sql, /^SELECT iit\.authorize_and_consume\(/);
  assert.deepEqual(c.params, ["package:IID-1:v1", "IID-1", "package", "appsheet_31", "run-1", "u@x", "In-Progress", "In-Progress", "2023-11-14T22:13:20.000Z"]);
  assert.ok(db.allClosed);
});
test("the body's caller_integration is ignored: the credential name is what reaches SQL", async () => {
  const db = new FakeConnector(() => [{ r: grant }]);
  await authorizeRoute(deps(db), { integration: "zap_texts", requestId: "rq", body: { ...body, caller_integration: "appsheet_31" } });
  assert.equal(db.calls[0]!.params![3], "zap_texts");
});
test("a failed or missing 3.1 read is passed as NULL status and NULL read time (SQL denies read_31_failed); the read error is reported, never a status", async () => {
  for (const read of [{ ok: false, error: "READ_TIMEOUT", latencyMs: 3000, detail: "request" } as ReadResult, { ok: true, missing: true, status: null, latencyMs: 5 } as ReadResult]) {
    const db = new FakeConnector(() => [{ r: { allowed: false, reason: "read_31_failed", action_id: "g1" } }]);
    const r = await authorizeRoute(deps(db, read), { integration: "appsheet_31", requestId: "rq", body });
    assert.equal(r.status, 200); assert.equal(r.body.allowed, false);
    assert.equal(db.calls[0]!.params![7], null); assert.equal(db.calls[0]!.params![8], null);
  }
});
test("a denial from SQL is passed through unchanged (allowed=false with its reason)", async () => {
  const db = new FakeConnector(() => [{ r: { allowed: false, reason: "hold", action_id: "g1" } }]);
  const r = await authorizeRoute(deps(db), { integration: "appsheet_31", requestId: "rq", body });
  assert.equal(r.status, 200); assert.equal(r.body.reason, "hold");
});
test("fail closed: DB connect failure, DB error, DB timeout and a malformed row shape all answer 502 allowed=false", async () => {
  const cases: [FakeConnector, string][] = [
    [new FakeConnector(() => [], true), "DB_ERROR"],
    [new FakeConnector(() => Object.assign(new Error("GATE_KEY_REUSED: x"), { code: "P0001" })), "DB_ERROR"],
    [new FakeConnector(() => delay(200, [{ r: grant }])), "DB_TIMEOUT"],
    [new FakeConnector(() => [{ r: grant }, { r: grant }]), "DB_SHAPE"],
  ];
  const fast = { ...cfg, timeouts: { ...cfg.timeouts, dbCallTimeoutMs: 50 } };
  for (const [db, want] of cases) {
    const r = await authorizeRoute({ ...deps(db), cfg: fast }, { integration: "appsheet_31", requestId: "rq", body });
    assert.equal(r.status, 502, want); assert.equal(r.body.allowed, false); assert.equal(r.body.reason, want);
    assert.ok(db.allClosed, "session closed after failure");
  }
});
test("DB error detail carries only the SQLSTATE and the leading error token, never parameter values", async () => {
  const logs: Record<string, unknown>[] = [];
  const db = new FakeConnector(() => Object.assign(new Error("GATE_KEY_REUSED: action_key package:IID-1:v1 belongs to text/IID-1"), { code: "P0001" }));
  await authorizeRoute(deps(db, found, logs), { integration: "appsheet_31", requestId: "rq", body });
  const e = logs.find((l) => l.event === "gate.authorize.db_failure")!;
  assert.equal(e.detail, "P0001:GATE_KEY_REUSED"); assert.ok(!JSON.stringify(logs).includes("IID-1:v1 belongs"));
});
test("missing fields → 400 BAD_REQUEST, no read and no SQL", async () => {
  const db = new FakeConnector(() => { throw new Error("must not be called"); });
  let reads = 0;
  const d: GateDeps = { ...deps(db), read31: async () => { reads++; return found; } };
  const r = await authorizeRoute(d, { integration: "appsheet_31", requestId: "rq", body: { iid: "x" } });
  assert.equal(r.status, 400); assert.equal(reads, 0); assert.equal(db.sessions.length, 0);
});
test("end to end through handle(): the AppSheet Find is performed with the configured app and key, then SQL is called", async () => {
  const fetched: { url: string; init: RequestInit }[] = [];
  const f = (async (url: string, init: RequestInit) => { fetched.push({ url, init }); return new Response(JSON.stringify([{ ID: "IID-1", "Deal Status": "In-Progress" }]), { status: 200 }); }) as unknown as typeof fetch;
  const db = new FakeConnector(() => [{ r: grant }]);
  const r = await handle(new Request("https://w.example/gate/authorize", { method: "POST", headers: { "x-iit-credential": "secret-a" }, body: JSON.stringify(body) }), ENV, { db, fetch: f, now: () => 1_700_000_000_000 });
  assert.equal(r.status, 200);
  assert.equal(fetched.length, 1); assert.match(fetched[0]!.url, /^https:\/\/api\.appsheet\.com\/api\/v2\/apps\/app-1\//);
  const sent = JSON.parse(String(fetched[0]!.init.body)) as { Action: string };
  assert.equal(sent.Action, "Find");
  assert.equal((fetched[0]!.init.headers as Record<string, string>).ApplicationAccessKey, "k");
  assert.equal(db.calls[0]!.params![7], "In-Progress");
});
test("end to end: a non-allowlisted AppSheet host/app makes NO request and the call is denied by SQL with a NULL read", async () => {
  let fetched = 0;
  const f = (async () => { fetched++; return new Response("[]"); }) as unknown as typeof fetch;
  const db = new FakeConnector(() => [{ r: { allowed: false, reason: "read_31_failed" } }]);
  const r = await handle(new Request("https://w.example/gate/authorize", { method: "POST", headers: { "x-iit-credential": "secret-a" }, body: JSON.stringify(body) }), { ...ENV, IIT_ALLOW_EXTERNAL_HOSTS: "" }, { db, fetch: f });
  assert.equal(r.status, 200); assert.equal(fetched, 0); assert.equal(db.calls[0]!.params![7], null);
  assert.equal((await r.json() as { read_31: string }).read_31, "HOST_NOT_ALLOWLISTED");
});
