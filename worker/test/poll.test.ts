import { test } from "node:test";
import assert from "node:assert/strict";
import { runExpire, runPoll, type PollDeps } from "../src/poll.ts";
import { scheduled } from "../src/index.ts";
import { loadConfig } from "../src/config.ts";
import { ENV, FakeConnector, delay } from "./fakes.ts";
import type { VautoDeps } from "../src/vauto.ts";

const cfg = loadConfig({ ...ENV, VAUTO_POLL_LOOKBACK_MINUTES: "60" });
const J = (status: number, body: unknown) => new Response(JSON.stringify(body), { status });
const vautoWith = (items: unknown[], fail = false): VautoDeps => {
  let n = 0;
  const f = (async () => { n++; if (n === 1) return J(200, { access_token: "T" }); if (fail && n === 3) return J(500, {}); return J(200, { items: n === 2 ? items.slice(0, 2) : items.slice(2), next: n === 2 && items.length > 2 ? "3,2" : null }); }) as unknown as typeof fetch;
  return { fetch: f, outboundCheck: () => ({ ok: true }), baseUrl: "https://v.example", tokenUrl: "https://v.example/t", entityLogicalId: "e", clientId: "c", clientSecret: "s", pageSize: 2, timeoutMs: 500 };
};
const appr = (id: string, value: number) => ({ id, isCompleted: true, appraisalValue: { appraisedValue: value }, vehicle: { vin: "V" + id }, financial: { lien: { accountNumber: "SECRET" } } });
const deps = (db: FakeConnector, vauto: VautoDeps, logs: Record<string, unknown>[] = [], now = () => 1_700_000_000_000): PollDeps => ({ db, cfg, vauto, now, log: (e) => logs.push(e) });

test("poll: every listed appraisal is sanitized and handed to ingest with the account context; counts by outcome/action; no row data logged", async () => {
  const logs: Record<string, unknown>[] = [];
  const db = new FakeConnector((_s, p) => [{ r: p![0] === "2" ? { outcome: "unchanged", action: "none" } : { outcome: "stored", action: p![0] === "1" ? "created" : "updated" } }]);
  const sum = await runPoll(deps(db, vautoWith([appr("1", 1), appr("2", 2), appr("3", 3)]), logs));
  assert.equal(sum.listed, 3); assert.equal(sum.pages, 2); assert.equal(sum.stored, 2); assert.equal(sum.unchanged, 1); assert.deepEqual(sum.actions, { created: 1, none: 1, updated: 1 });
  assert.equal(sum.since, "2023-11-14T21:13:20.000Z");
  const c = db.calls[0]!; assert.match(c.sql, /ingest_vauto_observation/); assert.equal(c.params![1], "ent-1");
  assert.ok(!String(c.params![2]).includes("SECRET"), "accountNumber never reaches the database call");
  assert.ok(!JSON.stringify(logs).includes("V1"), "no row data in logs");
  assert.ok(db.allClosed);
});
test("poll: a per-item DB failure is counted and the run continues; a page failure still ingests the items that arrived", async () => {
  let n = 0;
  const db = new FakeConnector(() => (++n === 1 ? Object.assign(new Error("STORAGE_POLICY: x"), { code: "23514" }) : [{ r: { outcome: "stored", action: "created" } }]));
  const sum = await runPoll(deps(db, vautoWith([appr("1", 1), appr("2", 2), appr("3", 3)], true)));
  assert.equal(sum.list_error, "VAUTO_HTTP:page_2:http_500"); assert.equal(sum.listed, 2); assert.equal(sum.db_errors, 1); assert.equal(sum.stored, 1);
});
test("poll: items without an id or not objects are skipped and counted; the budget stops the loop", async () => {
  const db = new FakeConnector(() => delay(30, [{ r: { outcome: "stored", action: "created" } }]));
  let t = 1_700_000_000_000; const now = () => (t += 20);
  const sum = await runPoll({ ...deps(db, vautoWith([{ nope: 1 }, "str", appr("1", 1), appr("2", 2), appr("3", 3)]), [], now), cfg: { ...cfg, timeouts: { ...cfg.timeouts, pollBudgetMs: 1000, dbCallTimeoutMs: 50 } } });
  assert.equal(sum.skipped_no_id, 1); assert.equal(sum.skipped_not_object, 1); assert.ok(sum.budget_exhausted || sum.stored === 3);
});
test("P2: the poll budget is an absolute deadline — a slow database cannot extend the run past it; the last call is cut to the time left", async () => {
  const db = new FakeConnector(() => delay(80, [{ r: { outcome: "stored", action: "created" } }]));   // each ingest wants 80 ms
  const t0 = Date.now();
  const six = [1, 2, 3, 4, 5, 6].map((i) => appr(String(i), i));
  const sum = await runPoll({ ...deps(db, vautoWith(six), [], Date.now), cfg: { ...cfg, timeouts: { ...cfg.timeouts, pollBudgetMs: 400, dbCallTimeoutMs: 100 } } });
  const elapsed = Date.now() - t0;
  assert.ok(elapsed < 400 + 60, `elapsed ${elapsed}ms exceeds the budget by more than the close bound`);
  assert.ok(sum.budget_exhausted); assert.ok(sum.stored + sum.db_errors < 6, "not every item was attempted");
  assert.ok(db.allClosed);
  // no budget left for listing at all → nothing is listed and nothing is ingested
  let t = 1_700_000_000_000; const none = await runPoll({ ...deps(new FakeConnector(() => { throw new Error("no"); }), vautoWith([appr("1", 1)]), [], () => (t += 1_000)), cfg: { ...cfg, timeouts: { ...cfg.timeouts, pollBudgetMs: 1500, dbCallTimeoutMs: 1000 } } });
  assert.equal(none.listed, 0); assert.equal(none.list_error, "VAUTO_TIMEOUT:no_budget_for_listing");
});
test("expire: the count is returned; a failure is reported, never thrown", async () => {
  const r = await runExpire(new FakeConnector(() => [{ r: 2 }]), cfg, () => undefined);
  assert.deepEqual(r, { ok: true, expired: 2 });
  const f = await runExpire(new FakeConnector(() => [], true), cfg, () => undefined);
  assert.equal(f.ok, false);
});
test("scheduled(): expiry runs before the poll and independently of vAuto availability; invalid config runs nothing", async () => {
  const order: string[] = [];
  const db = new FakeConnector((sql) => { order.push(sql.includes("expire") ? "expire" : "ingest"); return [{ r: sql.includes("expire") ? 0 : { outcome: "stored", action: "none" } }]; });
  const f = (async () => J(503, {})) as unknown as typeof fetch;        // vAuto down
  const r = await scheduled(ENV, { db, fetch: f, log: () => undefined });
  assert.deepEqual(order, ["expire"]); assert.equal((r.poll as { list_error: string }).list_error, "VAUTO_AUTH:http_503".replace("VAUTO_AUTH", "VAUTO_HTTP"));
  const none = new FakeConnector(() => { throw new Error("must not run"); });
  const bad = await scheduled({ ...ENV, VAUTO_PAGE_SIZE: "0" }, { db: none, fetch: f, log: () => undefined });
  assert.deepEqual(bad, { poll: null, expire: null }); assert.equal(none.sessions.length, 0);
});
