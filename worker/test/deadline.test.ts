import { test } from "node:test";
import assert from "node:assert/strict";
import { race, TimeoutErr } from "../src/deadline.ts";
import { callOne } from "../src/db.ts";
import { FakeConnector, delay } from "./fakes.ts";

test("race: resolves in time, rejects TimeoutErr after, runs onLate for a late value; ms<=0 rejects at once", async () => {
  assert.equal(await race(delay(5, "v"), 100, "p"), "v");
  await assert.rejects(race(delay(100, "v"), 5, "p"), (e: unknown) => e instanceof TimeoutErr && (e as TimeoutErr).phase === "p");
  let late: string | null = null;
  await assert.rejects(race(delay(20, "L"), 5, "p", (v) => { late = v; }));
  await delay(40, null); assert.equal(late, "L");
  await assert.rejects(race(delay(1, "v"), 0, "zero"), TimeoutErr);
});
test("callOne: one session, one statement, closed afterwards; a late connect is closed and never queried", async () => {
  const db = new FakeConnector(() => [{ r: 7 }]);
  const r = await callOne<number>(db, "SELECT iit.expire_stale_attempts(now()) AS r", [], 100, 50);
  assert.deepEqual(r, { ok: true, value: 7 }); assert.equal(db.sessions.length, 1); assert.ok(db.allClosed);
  const slow = new FakeConnector(() => [{ r: 1 }], false, 60);
  const t = await callOne(slow, "SELECT 1 AS r", [], 20, 10);
  assert.deepEqual(t, { ok: false, error: "DB_TIMEOUT", detail: "connect" });
  await delay(80, null); assert.equal(slow.sessions.length, 1); assert.equal(slow.sessions[0]!.log.length, 0); assert.ok(slow.allClosed);
});
