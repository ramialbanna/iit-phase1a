import { test } from "node:test";
import assert from "node:assert/strict";
import { reportRoute, type GateDeps } from "../src/gate_routes.ts";
import { loadConfig } from "../src/config.ts";
import { ENV, FakeConnector, delay } from "./fakes.ts";

const cfg = loadConfig(ENV);
const deps = (db: FakeConnector): GateDeps => ({ db, cfg: { ...cfg, timeouts: { ...cfg.timeouts, dbCallTimeoutMs: 50 } }, read31: async () => { throw new Error("no read on report"); }, now: Date.now, log: () => undefined });
const body = { attempt_id: "11111111-1111-4111-8111-111111111111", outcome: "completed", evidence: { package_id: "PK1" }, caller_run_ref: "run-1", caller_integration: "zap_texts" };

test("the verified integration and run ref reach report_action_outcome; evidence is serialized; result passed through", async () => {
  const db = new FakeConnector(() => [{ r: { recorded: true, result: "completed", state: "completed", completed_after_hold: false } }]);
  const r = await reportRoute(deps(db), { integration: "appsheet_31", requestId: "rq", body });
  assert.equal(r.status, 200); assert.equal(r.body.state, "completed");
  assert.deepEqual(db.calls[0]!.params, [body.attempt_id, "completed", JSON.stringify({ package_id: "PK1" }), "appsheet_31", "run-1"]);
});
test("wrong integration (SQL recorded=false) → 403; the body's caller_integration never substitutes", async () => {
  const db = new FakeConnector(() => [{ r: { recorded: false, result: "wrong_integration", state: "in_progress" } }]);
  const r = await reportRoute(deps(db), { integration: "zap_texts", requestId: "rq", body });
  assert.equal(r.status, 403); assert.equal(db.calls[0]!.params![3], "zap_texts");
});
test("server-side validation refusals are the caller's error (400): bad outcome, unknown attempt, evidence outside the allowlist", async () => {
  for (const [msg, code] of ([["GATE_OUTCOME: done", "P0001"], ["ATTEMPT_UNKNOWN: x", "P0001"], ["STORAGE_POLICY: gated_actions.outcome_evidence contains a key outside allowlist", "23514"]] as [string, string][])) {
    const db = new FakeConnector(() => Object.assign(new Error(msg), { code }));
    const r = await reportRoute(deps(db), { integration: "appsheet_31", requestId: "rq", body });
    assert.equal(r.status, 400, msg); assert.equal(r.body.recorded, false); assert.equal(r.body.reason, msg.split(":")[0]);
  }
});
test("infrastructure failures → 502 recorded=false (the caller must not treat the outcome as recorded)", async () => {
  for (const db of [new FakeConnector(() => [], true), new FakeConnector(() => delay(200, [{ r: {} }])), new FakeConnector(() => Object.assign(new Error("connection reset"), { code: "08006" }))]) {
    const r = await reportRoute(deps(db), { integration: "appsheet_31", requestId: "rq", body });
    assert.equal(r.status, 502); assert.equal(r.body.recorded, false);
  }
});
test("missing attempt_id/outcome → 400 without SQL; non-object evidence becomes {}", async () => {
  const db = new FakeConnector(() => [{ r: { recorded: true } }]);
  const r = await reportRoute(deps(db), { integration: "appsheet_31", requestId: "rq", body: { outcome: "completed" } });
  assert.equal(r.status, 400); assert.equal(db.sessions.length, 0);
  await reportRoute(deps(db), { integration: "appsheet_31", requestId: "rq", body: { ...body, evidence: ["x"] } });
  assert.equal(db.calls[0]!.params![2], "{}");
});
