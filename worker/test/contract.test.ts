import { test } from "node:test";
import assert from "node:assert/strict";
import { handle } from "../src/index.ts";
import { ENV, FakeConnector } from "./fakes.ts";
import { loadConfig, validateConfig } from "../src/config.ts";
import { identify, outboundGate, safeEqual } from "../src/gate.ts";

const req = (path: string, init: RequestInit = {}) => new Request(`https://w.example${path}`, { method: "POST", ...init });
const noDb = new FakeConnector(() => { throw new Error("db must not be touched"); });

test("flag off: every route is 404 ROUTES_DISABLED, even with a valid credential; nothing else runs", async () => {
  for (const p of ["/health", "/gate/authorize", "/gate/report", "/x"]) {
    const r = await handle(req(p, { headers: { "x-iit-credential": "secret-a" } }), { ...ENV, IIT_ROUTES_ENABLED: "false" }, { db: noDb });
    assert.equal(r.status, 404); assert.equal((await r.json() as { reason: string }).reason, "ROUTES_DISABLED");
  }
});
test("credential precedence: unknown or missing → 401 before any body is read; the body can never name the integration", async () => {
  const r = await handle(req("/gate/authorize", { body: JSON.stringify({ caller_integration: "appsheet_31", action_key: "k", iid: "i", action: "package" }) }), ENV, { db: noDb });
  assert.equal(r.status, 401);
  const r2 = await handle(req("/gate/authorize", { headers: { "x-iit-credential": "nope" } }), ENV, { db: noDb });
  assert.equal(r2.status, 401);
});
test("constant-time compare and identification by secret only", () => {
  assert.equal(safeEqual("abc", "abc"), true); assert.equal(safeEqual("abc", "abd"), false); assert.equal(safeEqual("abc", "ab"), false);
  const cfg = loadConfig(ENV);
  assert.equal(identify(cfg, "secret-z"), "zap_texts"); assert.equal(identify(cfg, "zap_texts"), null); assert.equal(identify(cfg, ""), null);
});
test("GET on a gate route → 405; unknown route → 404 with the integration logged", async () => {
  const logs: Record<string, unknown>[] = [];
  const r = await handle(new Request("https://w.example/gate/authorize", { headers: { "x-iit-credential": "secret-a" } }), ENV, { db: noDb, log: (e) => logs.push(e) });
  assert.equal(r.status, 405);
  const r2 = await handle(req("/nope", { headers: { "x-iit-credential": "secret-a" } }), ENV, { db: noDb, log: (e) => logs.push(e) });
  assert.equal(r2.status, 404); assert.equal(logs.at(-1)?.integration, "appsheet_31");
});
test("config validation: a bad timeout is a 500 CONFIG_INVALID; health is 200 when the flag is on", async () => {
  const r = await handle(req("/health"), { ...ENV, IIT_DB_CALL_TIMEOUT_MS: "0" }, { db: noDb });
  assert.equal(r.status, 500);
  const h = await handle(new Request("https://w.example/health"), ENV, { db: noDb });
  assert.equal(h.status, 200);
  assert.equal(validateConfig(loadConfig({ ...ENV, VAUTO_PAGE_SIZE: "500" })), "vAuto page size must be 1..100 (API max)");
});
test("outbound gate: the configured AppSheet app on an allowlisted host only; vAuto hosts must be allowlisted", () => {
  const cfg = loadConfig(ENV);
  assert.deepEqual(outboundGate(cfg, { kind: "appsheet", host: "api.appsheet.com", appId: "app-1" }), { ok: true });
  assert.equal(outboundGate(cfg, { kind: "appsheet", host: "api.appsheet.com", appId: "app-2" }).ok, false);
  assert.equal(outboundGate(cfg, { kind: "appsheet", host: "evil.example", appId: "app-1" }).ok, false);
  assert.equal(outboundGate(cfg, { kind: "vauto", url: "https://vauto.example/api/appraisals" }).ok, true);
  assert.equal(outboundGate(cfg, { kind: "vauto", url: "https://vauto.example/oauth/token" }).ok, true);
  assert.equal(outboundGate(cfg, { kind: "vauto", url: "https://other.example/x" }).ok, false);
  // P1 (v0.1 review): vAuto credentials may not go to ANY other allowlisted host, a different port/scheme, or an unconfigured vAuto URL
  assert.deepEqual(outboundGate(cfg, { kind: "vauto", url: "https://api.appsheet.com/x" }), { ok: false, reason: "ORIGIN_NOT_VAUTO" });
  assert.deepEqual(outboundGate(cfg, { kind: "vauto", url: "https://vauto.example:8443/api" }), { ok: false, reason: "ORIGIN_NOT_VAUTO" });
  assert.deepEqual(outboundGate(cfg, { kind: "vauto", url: "http://vauto.example/api" }), { ok: false, reason: "ORIGIN_NOT_VAUTO" });
  assert.deepEqual(outboundGate(cfg, { kind: "vauto", url: "https://vauto.example.evil/api" }), { ok: false, reason: "ORIGIN_NOT_VAUTO" });
  assert.equal(outboundGate(loadConfig({ ...ENV, IIT_ALLOW_EXTERNAL_HOSTS: "api.appsheet.com" }), { kind: "vauto", url: "https://vauto.example/api/appraisals" }).ok, false, "origin pinned AND host allowlisted");
  assert.equal(outboundGate(loadConfig({ ...ENV, IIT_APPSHEET_APP_ID: "" }), { kind: "appsheet", host: "api.appsheet.com", appId: "" }).ok, false);
});
test("P1: duplicate credential values are a config error (500 on every route) and identify nobody", async () => {
  const dup = { ...ENV, IIT_CRED_ZAP_TEXTS: "secret-a" };
  assert.equal(validateConfig(loadConfig(dup)), "credentials appsheet_31 and zap_texts share one secret value");
  assert.equal(identify(loadConfig(dup), "secret-a"), null);
  const r = await handle(req("/gate/authorize", { headers: { "x-iit-credential": "secret-a" }, body: "{}" }), dup, { db: noDb });
  assert.equal(r.status, 500); const b = await r.json() as { reason: string; detail: string };
  assert.equal(b.reason, "CONFIG_INVALID"); assert.ok(!b.detail.includes("secret-a"), "the value is never reported");
  assert.equal(validateConfig(loadConfig({ ...ENV, VAUTO_BASE_URL: "http://vauto.example" })), "VAUTO_BASE_URL must be https");
});
test("secrets never appear in config output beyond credential NAMES", () => {
  const cfg = loadConfig(ENV);
  const s = JSON.stringify({ ...cfg, credentials: Object.keys(cfg.credentials) });
  for (const secret of ["secret-a", "secret-z", "csec", "k"]) assert.ok(!s.includes(`"${secret}"`));
});
