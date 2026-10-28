// The Worker is read-only towards AppSheet and vAuto: the only AppSheet action string is "Find" and vAuto is only GET.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const src = readdirSync("src").filter((f) => f.endsWith(".ts")).map((f) => [f, readFileSync(`src/${f}`, "utf8")] as const);
test("no AppSheet Add/Edit/Delete action and no vAuto POST exists in src/", () => {
  for (const [f, s] of src) {
    assert.ok(!/Action:\s*"(Add|Edit|Delete)"/.test(s), `${f} constructs a writing AppSheet action`);
    const posts = [...s.matchAll(/method:\s*"POST"/g)].length;
    if (f === "vauto.ts") assert.equal(posts, 1, "vauto.ts: only the token request may POST");
    else if (f === "read31.ts") assert.equal(posts, 1, "read31.ts: the Find action is a POST to /Action; nothing else");
    else assert.equal(posts, 0, `${f} must not POST`);
  }
  const r31 = src.find(([f]) => f === "read31.ts")![1];
  assert.equal([...r31.matchAll(/Action:\s*"Find"/g)].length, 1);
});
test("no secret-bearing environment key is ever logged by name-only accident: log calls never reference *_KEY / *_SECRET / IIT_CRED_ values", () => {
  for (const [f, s] of src) {
    for (const m of s.matchAll(/log\(\{[^}]*\}\)/g)) assert.ok(!/(appKey|clientSecret|clientId|credentials|IIT_DB_URL|connectionString)/.test(m[0]), `${f}: ${m[0]}`);
  }
});
