// v0.52 (Codex, 25 Oct): controlled read-error fixtures through the ACTUAL read31Status path — injected HTTP
// responses, NOT fakeRead31 (which bypasses response interpretation). Each fixture asserts the classification and
// that NO status is trusted on failure (`status` absent / never a string). Found and missing are the positive controls.
import { test } from "node:test";
import assert from "node:assert/strict";
import { read31Status, type ReadResult } from "../src/read31.ts";

const K = "ID", S = "Deal Status", IID = "dcdd0bd1";
const http = (status: number, body: string) => (async () => new Response(body, { status, headers: { "content-type": "application/json" } })) as typeof fetch;
const deps = (f: typeof fetch, log: string[] = []) => ({
  fetch: f, outboundCheck: () => ({ ok: true as const }), appKey: "k", appId: "copy",
  table: "01_MY CAR LIST", keyColumn: K, statusColumn: S,
  beforeFetch: async (host: string, target: string) => { log.push(`${host}/${target}`); },
});
const noStatusTrusted = (r: ReadResult) => {
  assert.equal(r.ok, false);
  assert.ok(!("status" in r), "a failed read must carry no status field");
};

test("control: found row (sampled test-app shape: all string values) => ok, status returned", async () => {
  const body = JSON.stringify([{ _RowNumber: "2", [K]: IID, VIN: "TSTRN5E3X0157650", [S]: "In-Progress", Deposit: "1000", Balance: "" }]);
  const r = await read31Status(deps(http(200, body)), IID, 1000);
  assert.deepEqual({ ok: r.ok, missing: (r as { missing: boolean }).missing, status: (r as { status: string }).status }, { ok: true, missing: false, status: "In-Progress" });
});
test("control: missing row (HTTP 200 `[]` as sampled) => ok, missing, status null", async () => {
  const r = await read31Status(deps(http(200, "[]")), "ZZZZ9999", 1000);
  assert.deepEqual({ ok: r.ok, missing: (r as { missing: boolean }).missing, status: (r as { status: null }).status }, { ok: true, missing: true, status: null });
});

test("fixture M1: malformed JSON text => READ_MALFORMED (not_json), no status", async () => {
  const r = await read31Status(deps(http(200, "[{\"ID\":\"dcdd0bd1\",")), IID, 1000);
  noStatusTrusted(r); assert.equal((r as { error: string }).error, "READ_MALFORMED"); assert.equal((r as { detail?: string }).detail, "not_json");
});
test("fixture M2: wrong shape — object instead of array (AppSheet error envelope style) => READ_MALFORMED", async () => {
  const r = await read31Status(deps(http(200, JSON.stringify({ Rows: [{ [K]: IID, [S]: "In-Progress" }] }))), IID, 1000);
  noStatusTrusted(r); assert.equal((r as { error: string }).error, "READ_MALFORMED"); assert.equal((r as { detail?: string }).detail, "body_not_array");
});
test("fixture M3: row without the key column / key not a string => READ_MALFORMED", async () => {
  for (const row of [{ [S]: "In-Progress" }, { [K]: 42, [S]: "In-Progress" }, { [K]: null, [S]: "In-Progress" }]) {
    const r = await read31Status(deps(http(200, JSON.stringify([row]))), IID, 1000);
    noStatusTrusted(r); assert.equal((r as { error: string }).error, "READ_MALFORMED", JSON.stringify(row));
  }
});
test("fixture M4: matching row but status missing / non-string => READ_MALFORMED (status never trusted)", async () => {
  for (const row of [{ [K]: IID }, { [K]: IID, [S]: 7 }, { [K]: IID, [S]: null }]) {
    const r = await read31Status(deps(http(200, JSON.stringify([row]))), IID, 1000);
    noStatusTrusted(r); assert.equal((r as { error: string }).error, "READ_MALFORMED", JSON.stringify(row));
  }
});
test("fixture D1: two rows with the SAME matching ID => READ_DUPLICATE (rows=2), no status", async () => {
  const r = await read31Status(deps(http(200, JSON.stringify([{ [K]: IID, [S]: "In-Progress" }, { [K]: IID, [S]: "Canceled" }]))), IID, 1000);
  noStatusTrusted(r); assert.equal((r as { error: string }).error, "READ_DUPLICATE"); assert.equal((r as { detail?: string }).detail, "rows=2");
});
test("fixture I1: single row with the WRONG ID => READ_IDENTITY_MISMATCH, its status is not trusted", async () => {
  const r = await read31Status(deps(http(200, JSON.stringify([{ [K]: "OTHER", [S]: "In-Progress" }]))), IID, 1000);
  noStatusTrusted(r); assert.equal((r as { error: string }).error, "READ_IDENTITY_MISMATCH");
});
test("fixture I2: matching row plus a foreign row => READ_IDENTITY_MISMATCH takes precedence over duplicate", async () => {
  const r = await read31Status(deps(http(200, JSON.stringify([{ [K]: IID, [S]: "In-Progress" }, { [K]: "OTHER", [S]: "In-Progress" }]))), IID, 1000);
  noStatusTrusted(r); assert.equal((r as { error: string }).error, "READ_IDENTITY_MISMATCH");
});
test("fixture H1: HTTP 4xx/5xx with a JSON body that LOOKS valid => READ_ERROR http_<status>, body ignored", async () => {
  for (const code of [401, 403, 404, 500, 503]) {
    const r = await read31Status(deps(http(code, JSON.stringify([{ [K]: IID, [S]: "In-Progress" }]))), IID, 1000);
    noStatusTrusted(r); assert.equal((r as { error: string }).error, "READ_ERROR"); assert.equal((r as { detail?: string }).detail, `http_${code}`);
  }
});
test("logging control: ONE missing-row invocation performs exactly one outbound-log write (ordering of other fixtures not independently asserted here)", async () => {
  const log: string[] = [];
  await read31Status(deps(http(200, "[]"), log), IID, 1000);
  assert.deepEqual(log, ["api.appsheet.com/copy"]);
});
