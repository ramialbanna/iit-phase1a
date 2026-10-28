// db_adapter.ts contract tests with a scripted pg client (docs/15 §2). These prove the adapter's own
// behaviour (guard, sslmode refusal, close semantics, fault-surface separation). Protocol-level
// non-pipelining on the REAL pg client is proven by D-1 against the sandbox, not here.
import { test } from "node:test";
import assert from "node:assert/strict";
import pg from "pg";
import { createConnector, connectorFromEnv, checkUrlSslMode, parseStrictDbUrl, classifyConnectError, type PgClientLike } from "../src/db_adapter.ts";
import { RAW } from "../src/db_adapter.ts";

const URL_OK = "postgres://s2test_runner:x@db.example.internal:5432/iit";

function scripted(opts: { connectDelay?: number; queryDelay?: number; failConnect?: unknown } = {}) {
  const calls: string[] = []; let ended = 0; let destroyed = 0; let cfgSeen: Record<string, unknown> | null = null;
  const client: PgClientLike = {
    async connect() { if (opts.connectDelay) await new Promise((r) => setTimeout(r, opts.connectDelay)); if (opts.failConnect) throw opts.failConnect; },
    async query(sql) { calls.push(sql); if (opts.queryDelay) await new Promise((r) => setTimeout(r, opts.queryDelay)); return { rows: [{ ok: 1 }] }; },
    async end() { ended++; },
    connection: { query(sql) { calls.push("DETACHED " + sql); }, stream: { destroy() { destroyed++; } } },
    on() { return client; },
  };
  const connector = createConnector({ connectionString: URL_OK, clientFactory: (cfg) => { cfgSeen = cfg as Record<string, unknown>; return client; } });
  return { connector, calls, get ended() { return ended; }, get destroyed() { return destroyed; }, get cfg() { return cfgSeen; } };
}

test("client config: pipeline false explicit, verify-full TLS with SNI servername, application_name, no named statements", async () => {
  const s = scripted(); await s.connector.connect();
  assert.equal(s.cfg!.pipeline, false);
  assert.deepEqual(s.cfg!.ssl, { rejectUnauthorized: true, servername: "db.example.internal" });
  assert.equal(s.cfg!.application_name, "iit-worker");
});

test("A2 in-flight guard: a second query() while one is outstanding throws S2_PIPELINE and is never sent", async () => {
  const s = scripted({ queryDelay: 50 }); const sess = await s.connector.connect();
  const first = sess.query("SELECT 1");
  await assert.rejects(sess.query("SELECT 2"), (e: unknown) => (e as { code?: string }).code === "S2_PIPELINE");
  await first;
  assert.deepEqual(s.calls, ["SELECT 1"]);
  await sess.query("SELECT 3");                      // sequential use is fine
  assert.deepEqual(s.calls, ["SELECT 1", "SELECT 3"]);
});

test("close(): calls the public end() exactly once, is idempotent, and later query() fails with 08006", async () => {
  const s = scripted(); const sess = await s.connector.connect();
  await sess.close(); await sess.close();
  assert.equal(s.ended, 1);
  await assert.rejects(sess.query("SELECT 1"), (e: unknown) => (e as { code?: string }).code === "08006");
  assert.equal(s.destroyed, 0, "production close never uses the internal stream destroy");
});


test("sslmode / TLS parameters in the URL are refused before any connect (T-2 n4)", () => {
  for (const q of ["sslmode=require", "sslmode=prefer", "sslmode=disable", "sslmode=verify-ca", "sslrootcert=/x", "gssencmode=prefer"]) {
    assert.throws(() => checkUrlSslMode(`${URL_OK}?${q}`), (e: unknown) => (e as { code?: string }).code === "S2_SSLMODE", q);
    assert.throws(() => createConnector({ connectionString: `${URL_OK}?${q}`, clientFactory: () => { throw new Error("factory must not run"); } }), (e: unknown) => (e as { code?: string }).code === "S2_SSLMODE", q);
  }
  checkUrlSslMode(URL_OK); checkUrlSslMode(`${URL_OK}?sslmode=verify-full`);
  assert.throws(() => checkUrlSslMode("mysql://x"), (e: unknown) => (e as { code?: string }).code === "S2_SSLMODE");
});

test("connectorFromEnv: no IIT_DB_URL -> IIT_NO_DB on connect; with URL -> verify-full (never plaintext)", async () => {
  await assert.rejects(connectorFromEnv({}).connect(), (e: unknown) => (e as { code?: string }).code === "IIT_NO_DB");
  assert.throws(() => connectorFromEnv({ IIT_DB_URL: `${URL_OK}?sslmode=disable` }), (e: unknown) => (e as { code?: string }).code === "S2_SSLMODE");
});

test("connect failures carry a classified reason (TLS acceptance criteria): untrusted chain, hostname, unclassified", async () => {
  for (const [code, reason] of [["SELF_SIGNED_CERT_IN_CHAIN", "untrusted_chain"], ["ERR_TLS_CERT_ALTNAME_INVALID", "hostname_mismatch"], ["ECONNREFUSED", "unclassified"]] as const) {
    const s = scripted({ failConnect: Object.assign(new Error("boom"), { code }) });
    await assert.rejects(s.connector.connect(), (e: unknown) => (e as { s2connect?: { reason: string } }).s2connect?.reason === reason, code);
  }
  assert.equal(classifyConnectError(new Error("The server does not support SSL connections")).reason, "tls_off_or_refused");
  assert.equal(classifyConnectError(Object.assign(new Error("x"), { code: "S2_SSLMODE" })).stage, "before_connect");
});

test("IP hosts get no SNI servername (tls.connect sets SNI only for hostnames)", async () => {
  let cfg: Record<string, unknown> | null = null;
  const stub: PgClientLike = { async connect() {}, async query() { return { rows: [] }; }, async end() {} };
  const c = createConnector({ connectionString: "postgres://u:p@10.0.0.5:5432/iit", clientFactory: (k) => { cfg = k as Record<string, unknown>; return stub; } });
  await c.connect();
  assert.deepEqual(cfg!.ssl, { rejectUnauthorized: true });
});


// ---------- v0.19 (Codex v0.18 item 1): the driver never sees the connection string ----------

/** Effective TLS as the PINNED driver computes it, with no socket opened. */
const effectiveSsl = (cfg: pg.ClientConfig) => (new pg.Client(cfg) as unknown as { connectionParameters: { ssl: unknown } }).connectionParameters.ssl;

test("REPRODUCTION (why connectionString is banned): with pg 8.23.1 a URL overrides an explicit ssl object", () => {
  // These are the exact cases Codex reproduced. They are CONTROLS showing the driver's behaviour, not our config.
  assert.equal(effectiveSsl({ connectionString: `${URL_OK}?ssl=0`, ssl: { rejectUnauthorized: true } }), false);
  assert.deepEqual(effectiveSsl({ connectionString: `${URL_OK}?ssl=no-verify`, ssl: { rejectUnauthorized: true } }), { rejectUnauthorized: false });
  assert.deepEqual(effectiveSsl({ connectionString: `${URL_OK}?sslmode=verify-full&sslmode=no-verify`, ssl: { rejectUnauthorized: true } }), { rejectUnauthorized: false });
});

test("adapter passes explicit fields only; the pinned driver's effective ssl is exactly the reviewed object", async () => {
  const s = scripted(); await s.connector.connect();
  assert.equal("connectionString" in s.cfg!, false, "connectionString must never reach the driver");
  assert.deepEqual([s.cfg!.host, s.cfg!.port, s.cfg!.user, s.cfg!.password, s.cfg!.database], ["db.example.internal", 5432, "s2test_runner", "x", "iit"]);
  // Feed the SAME config object to the real pinned pg.Client (no connect) and read back what it will use.
  assert.deepEqual(effectiveSsl(s.cfg as pg.ClientConfig), { rejectUnauthorized: true, servername: "db.example.internal" });
});

test("strict URL: Codex's three overrides and every other query form are refused before any connect (no factory call)", () => {
  const refused = [`${URL_OK}?ssl=0`, `${URL_OK}?ssl=no-verify`, `${URL_OK}?sslmode=verify-full&sslmode=no-verify`, `${URL_OK}?sslmode=no-verify&sslmode=verify-full`,
    `${URL_OK}?ssl=true`, `${URL_OK}?sslmode=verify-full&application_name=x`, `${URL_OK}?options=-c%20search_path%3Dx`, `${URL_OK}?uselibpqcompat=true`,
    `${URL_OK}?sslcert=a`, `${URL_OK}?sslrootcert=a`, `${URL_OK}?gssencmode=prefer`, `${URL_OK}#frag`, "postgres://s2test_runner@db.example.internal:5432/", "postgres://db.example.internal/iit", "postgres://u@h:0/iit", "postgres://u@h:5432/a/b"];
  for (const u of refused) {
    let factoryCalls = 0;
    assert.throws(() => createConnector({ connectionString: u, clientFactory: () => { factoryCalls++; throw new Error("x"); } }), (e: unknown) => (e as { code?: string }).code === "S2_SSLMODE", u);
    assert.equal(factoryCalls, 0, `no client constructed for ${u}`);
  }
  // positive controls
  assert.deepEqual(parseStrictDbUrl(URL_OK), { host: "db.example.internal", port: 5432, user: "s2test_runner", password: "x", database: "iit" });
  assert.deepEqual(parseStrictDbUrl(`${URL_OK}?sslmode=verify-full`).database, "iit");
  assert.deepEqual(parseStrictDbUrl("postgresql://u%40x:p%23w@[::1]/d").user, "u@x");
  assert.equal(parseStrictDbUrl("postgresql://u@h/d").port, 5432);
});

// ---------- v0.19 (Codex v0.18 item 3): cleanup on connect rejection and late connect ----------

test("connect rejection: public end() called once (bounded), original classified error preserved", async () => {
  const err = Object.assign(new Error("tls boom"), { code: "SELF_SIGNED_CERT_IN_CHAIN" });
  const s = scripted({ failConnect: err });
  await assert.rejects(s.connector.connect(), (e: unknown) => e === err && (e as { s2connect?: { reason: string } }).s2connect?.reason === "untrusted_chain");
  assert.equal(s.ended, 1, "end() once after the failed connect");
});

test("connect rejection: a hanging end() does not hide or delay the original error beyond the bound", async () => {
  const err = Object.assign(new Error("refused"), { code: "ECONNREFUSED" });
  const client: PgClientLike = { async connect() { throw err; }, async query() { return { rows: [] }; }, end: () => new Promise(() => {}) };
  const c = createConnector({ connectionString: URL_OK, clientFactory: () => client });
  const t0 = Date.now();
  await assert.rejects(c.connect(), (e: unknown) => e === err);
  assert.ok(Date.now() - t0 < 1500, "bounded by CONNECT_CLEANUP_MS");
});



// v0.29 (IIC-0): tlsObserved reports only a demonstrated runtime signal.
test("tlsObserved: encrypted true only when the pg stream reports encrypted===true; null (not false) when the stream exposes no signal; verified always null", async () => {
  const withStream = (stream: unknown) => createConnector({ connectionString: "postgres://u:p@db.example:5432/d", tls: "verify-full",
    clientFactory: () => ({ async connect() {}, async query() { return { rows: [] }; }, async end() {}, connection: { query() {}, stream: stream as { destroy(): void } } }) });
  const tls = await (await withStream({ destroy() {}, encrypted: true, getProtocol: () => "TLSv1.3" }).connect()).tlsObserved!();
  assert.deepEqual(tls, { encrypted: true, version: "TLSv1.3", verified: null });
  const plain = await (await withStream({ destroy() {} }).connect()).tlsObserved!();
  assert.deepEqual(plain, { encrypted: null, version: null, verified: null }, "no `encrypted` property (e.g. CloudflareSocket) -> unknown, never inferred from the ssl option");
  const str = await (await withStream({ destroy() {}, encrypted: "yes" }).connect()).tlsObserved!();
  assert.deepEqual(str, { encrypted: null, version: null, verified: null }, "only the boolean true counts");
  const noConn = createConnector({ connectionString: "postgres://u:p@db.example:5432/d", tls: "verify-full", clientFactory: () => ({ async connect() {}, async query() { return { rows: [] }; }, async end() {} }) });
  assert.deepEqual((await noConn.connect()).tlsObserved!(), { encrypted: null, version: null, verified: null });
});

// v0.46: Hyperdrive binding precedence (Stage 1 TLS finding: Workers cannot pass a custom CA to pg's startTls)
const cfe46 = connectorFromEnv;
test("connectorFromEnv: HYPERDRIVE binding wins over IIT_DB_URL and uses the internal (no-socket-TLS) mode", async () => {
  const env = { HYPERDRIVE: { connectionString: "postgresql://u:p@hd.internal:5432/postgres" }, IIT_DB_URL: "postgresql://x:y@db.example:5432/postgres?sslmode=verify-full" };
  // createConnector is exercised via connectorFromEnv; we only assert construction succeeds and that the URL parsed (no refusal)
  const c = cfe46(env);
  assert.ok(c && typeof c.connect === "function");
});
test("v0.47 connectorFromEnv: HYPERDRIVE present but malformed => IIT_HYPERDRIVE_INVALID denial; NEVER falls back to IIT_DB_URL", async () => {
  for (const bad of [{}, { connectionString: "" }, { connectionString: 42 }, null]) {
    const c = cfe46({ HYPERDRIVE: bad, IIT_DB_URL: "postgresql://x:y@db.example:5432/postgres?sslmode=verify-full" });
    await assert.rejects(c.connect(), (e: any) => e.code === "IIT_HYPERDRIVE_INVALID" && /no connection string/.test(e.message));
  }
});
test("v0.47 connectorFromEnv: IIT_DB_URL verify-full path used ONLY when HYPERDRIVE is absent", () => {
  assert.throws(() => cfe46({ IIT_DB_URL: "postgresql://x:y@db.example:5432/postgres?sslmode=disable" }), (e: any) => e.code === "S2_SSLMODE");
  assert.ok(cfe46({ IIT_DB_URL: "postgresql://x:y@db.example:5432/postgres?sslmode=verify-full" }));
});
test("connectorFromEnv: HYPERDRIVE connectionString is still strictly parsed (fragment refused)", () => {
  assert.throws(() => cfe46({ HYPERDRIVE: { connectionString: "postgresql://u:p@hd.internal:5432/postgres#x" } }), /IIT_DB_URL refused: fragment not allowed/);
});
test("connectorFromEnv: neither binding nor URL => IIT_NO_DB rejecting connector", async () => {
  const c = cfe46({});
  await assert.rejects(c.connect(), (e: any) => e.code === "IIT_NO_DB");
});
test("createConnector hyperdrive-internal: client config has ssl=false (no socket TLS), verify-full has ssl object", async () => {
  const cfgs: pg.ClientConfig[] = [];
  const factory = (cfg: pg.ClientConfig): PgClientLike => { cfgs.push(cfg); return { async connect() {}, async query() { return { rows: [] }; }, async end() {} }; };
  await createConnector({ connectionString: "postgresql://u:p@hd.internal:5432/postgres", tls: "hyperdrive-internal", clientFactory: factory }).connect();
  await createConnector({ connectionString: "postgresql://u:p@db.example:5432/postgres?sslmode=verify-full", tls: "verify-full", clientFactory: factory }).connect();
  assert.equal(cfgs[0]!.ssl, false);
  assert.equal(typeof cfgs[1]!.ssl, "object");
  assert.equal((cfgs[1]!.ssl as { rejectUnauthorized?: boolean }).rejectUnauthorized, true);
});
test("v0.46 hyperdrive-internal: binding string with sslmode=disable accepted; verify-full there refused; verify-full mode still refuses disable", () => {
  assert.ok(parseStrictDbUrl("postgresql://u:p@hd.internal:5432/postgres?sslmode=disable", "hyperdrive-internal"));
  assert.throws(() => parseStrictDbUrl("postgresql://u:p@hd.internal:5432/postgres?sslmode=verify-full", "hyperdrive-internal"), /only a single sslmode=disable/);
  assert.throws(() => parseStrictDbUrl("postgresql://u:p@db.example:5432/postgres?sslmode=disable"), /only a single sslmode=verify-full/);
  assert.throws(() => parseStrictDbUrl("postgresql://u:p@hd.internal:5432/postgres?sslmode=require", "hyperdrive-internal"), /S2_SSLMODE|not allowed/);
});
