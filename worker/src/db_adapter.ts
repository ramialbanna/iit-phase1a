// Postgres adapter on `pg@8.23.1` — carried over VERBATIM from the S2 spike Worker (v0.79, Codex-accepted), with only the
// environment names changed (IIT_DB_URL → IIT_DB_URL, application_name). Approved dependency DC-1/DC-3; lockfile unchanged.
// Design: docs/15 §1–§2. Requirements (docs/02_r1_orchestration.md):
//   A1  one physical backend per transaction: a NEW Client per connect(); nothing is pooled or reused.
//   A2  NO pipelining: `pipeline: false` is set explicitly, and an in-flight guard raises S2_PIPELINE
//       if query() is called while a statement is outstanding (proven at the protocol level by D-1).
//   A3  the production PgSession surface is query() + close() only. The raw pg client hangs off a
//       non-enumerable symbol (RAW) so that the harness module fault.ts can build its primitives from it;
//       fault.ts is never imported by the product entry (index.ts), so D-3 finds none of it in the bundle.
//   A4  no PREPARE TRANSACTION, no named prepared statements (`name:` is never used).
//   A5  the URL comes from the IIT_DB_URL secret and is never logged; sslmode other than absent or
//       verify-full is refused BEFORE any TCP connect (docs/15 §1, T-2 n4). TLS settings are built in
//       code, never taken from the URL.
import pg from "pg";
import type { PgConnector, PgSession } from "./types.ts";

/** Non-enumerable handle to the underlying pg client (harness use only; see fault.ts). */
export const RAW = Symbol.for("iit.s2.raw-client");
/** Bound on the public end() after a failed connect. */
export const CONNECT_CLEANUP_MS = 1000;

export interface AdapterOptions {
  connectionString: string;
  /** TLS. `verify-full` (default): rejectUnauthorized + SNI servername from the URL host.
   *  `plaintext-local` is for LOCAL validation against the sandbox only; connectorFromEnv() never sets it. */
  tls?: "verify-full" | "plaintext-local" | "hyperdrive-internal";
  /** `hyperdrive-internal` (v0.46): the connection string comes from a Hyperdrive binding. The Worker→Hyperdrive leg is
   *  Cloudflare-internal (no TLS on the socket; Hyperdrive answers 'N' to SSLRequest); the Hyperdrive→origin leg is
   *  TLS with the mode and CA configured on the Hyperdrive resource (Stage 1: verify-full + uploaded Supabase CA). */
  /** Extra CA (PEM) for T-2 synthetic endpoints under Node. Ignored under Workers (docs/15 §4.2). */
  ca?: string;
  /** Client-side connect bound; the caller's race() is the authoritative deadline. */
  connectionTimeoutMillis?: number;
  /** Test seam: replaces `new pg.Client(cfg)`. Never set in production. */
  clientFactory?: (cfg: pg.ClientConfig) => PgClientLike;
}

/** The subset of pg.Client the adapter uses (lets unit tests substitute a scripted client). */
export interface PgClientLike {
  connect(): Promise<void>;
  query(sql: string, values?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
  end(): Promise<void>;
  connection?: { query(sql: string): void; stream?: { destroy(): void; encrypted?: unknown; getProtocol?(): string | null } };
  on?(evt: "error", f: (e: unknown) => void): unknown;
}

/** Stage reached by a connect attempt, for the TLS acceptance criteria (docs/15 §4.2). `pg` exposes
 *  no handshake hooks, so the adapter records what it can observe: the error class and message.
 *  Finer stages (sslrequest_sent / sslresponse) come from the T-2 proxy log, not from here. */
export interface ConnectFailure { stage: "before_connect" | "connect_failed"; code: string | null; reason: "untrusted_chain" | "hostname_mismatch" | "sslmode_refused" | "tls_off_or_refused" | "unclassified"; message: string }

const UNTRUSTED = new Set(["UNABLE_TO_VERIFY_LEAF_SIGNATURE", "SELF_SIGNED_CERT_IN_CHAIN", "DEPTH_ZERO_SELF_SIGNED_CERT", "CERT_HAS_EXPIRED", "UNABLE_TO_GET_ISSUER_CERT_LOCALLY", "UNABLE_TO_GET_ISSUER_CERT", "CERT_UNTRUSTED"]);
export function classifyConnectError(e: unknown): ConnectFailure {
  const code = (e as { code?: string })?.code ?? null;
  const message = e instanceof Error ? e.message : String(e);
  if (code === "S2_SSLMODE") return { stage: "before_connect", code, reason: "sslmode_refused", message };
  if (code && UNTRUSTED.has(code)) return { stage: "connect_failed", code, reason: "untrusted_chain", message };
  if (code === "ERR_TLS_CERT_ALTNAME_INVALID") return { stage: "connect_failed", code, reason: "hostname_mismatch", message };
  if (/server does not support SSL|SSL off|sslresponse/i.test(message)) return { stage: "connect_failed", code, reason: "tls_off_or_refused", message };
  return { stage: "connect_failed", code, reason: "unclassified", message };
}

/** Strict URL parsing (v0.19, Codex v0.18 item 1). The driver is NEVER given the connection string: with
 *  `pg` 8.23.1 a `connectionString` containing `?ssl=0`, `?ssl=no-verify` or a repeated `sslmode` overrides an
 *  explicit `ssl` object (reproduced from the locked pg-connection-string source). So the URL is reduced here
 *  to explicit fields (host, port, user, password, database) and the TLS object is built in code.
 *  Allowed query parameters: none, or exactly one `sslmode=verify-full`. Every other key, any repeated key,
 *  any `ssl`/`sslmode` variant, hash fragments and unknown protocols are refused BEFORE any socket is opened. */
export interface StrictDbTarget { host: string; port: number; user: string; password: string | undefined; database: string }
export function parseStrictDbUrl(connectionString: string, mode: "verify-full" | "hyperdrive-internal" = "verify-full"): StrictDbTarget {
  const refuse = (why: string) => Object.assign(new Error(`IIT_DB_URL refused: ${why}`), { code: "S2_SSLMODE" });
  // v0.46: a Hyperdrive binding's string carries `sslmode=disable` — it describes the Cloudflare-internal
  // Worker→Hyperdrive leg; TLS to the origin is configured on the Hyperdrive resource. Only that exact value is
  // accepted in hyperdrive-internal mode; in verify-full mode the rule below is unchanged.
  const allowedSslmode = mode === "hyperdrive-internal" ? "disable" : "verify-full";
  let u: URL;
  try { u = new URL(connectionString); } catch { throw refuse("not a valid URL"); }
  if (!/^postgres(ql)?:$/.test(u.protocol)) throw refuse("protocol must be postgres:// or postgresql://");
  if (u.hash) throw refuse("fragment not allowed");
  const keys = [...u.searchParams.keys()];
  if (keys.length > 1) throw refuse(`only one query parameter is allowed, got ${keys.length}`);
  if (keys.length === 1) {
    const all = u.searchParams.getAll("sslmode");
    if (keys[0] !== "sslmode" || all.length !== 1 || all[0] !== allowedSslmode) throw refuse(`query parameter ${keys[0]}=${u.searchParams.get(keys[0]!)} not allowed; only a single sslmode=${allowedSslmode} is`);
  }
  if (!u.hostname) throw refuse("host missing");
  const port = u.port === "" ? 5432 : Number(u.port);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) throw refuse("port invalid");
  const database = decodeURIComponent(u.pathname.replace(/^\//, ""));
  if (!database || database.includes("/")) throw refuse("database name missing or invalid");
  if (!u.username) throw refuse("user missing");
  return { host: u.hostname.replace(/^\[|\]$/g, ""), port, user: decodeURIComponent(u.username), password: u.password ? decodeURIComponent(u.password) : undefined, database };
}
/** Kept for callers that only need the yes/no answer. */
export function checkUrlSslMode(connectionString: string): void { parseStrictDbUrl(connectionString); }

export function createConnector(opts: AdapterOptions): PgConnector {
  const tls = opts.tls ?? "verify-full";
  const target = parseStrictDbUrl(opts.connectionString, tls === "hyperdrive-internal" ? "hyperdrive-internal" : "verify-full");  // refuses before any socket
  const host = target.host;
  const ssl: pg.ClientConfig["ssl"] = (tls === "plaintext-local" || tls === "hyperdrive-internal") ? false
    : { rejectUnauthorized: true, ...(opts.ca ? { ca: opts.ca } : {}), ...(/^[\d.]+$|:/.test(host) ? {} : { servername: host }) };
  const factory = opts.clientFactory ?? ((cfg: pg.ClientConfig) => new pg.Client(cfg) as unknown as PgClientLike);
  return {
    async connect(): Promise<PgSession> {
      // Explicit fields only. `connectionString` is deliberately NOT passed (see parseStrictDbUrl).
      const client = factory({
        host: target.host, port: target.port, user: target.user, database: target.database,
        ...(target.password !== undefined ? { password: target.password } : {}),
        ssl,
        connectionTimeoutMillis: opts.connectionTimeoutMillis ?? 5000,
        application_name: "iit-worker",
        // A2: explicit. pg defaults to false; stating it makes the choice reviewable (docs/15 §1).
        ...({ pipeline: false } as object),
      } as pg.ClientConfig);
      client.on?.("error", () => { /* surfaced through the pending query's rejection; never unhandled */ });
      try { await client.connect(); } catch (e) {
        // Codex v0.18 item 3: bounded cleanup of a half-open client through the public end(); the ORIGINAL
        // classified error is preserved whatever end() does.
        const original = Object.assign(e instanceof Error ? e : new Error(String(e)), { s2connect: classifyConnectError(e) });
        await Promise.race([client.end().catch(() => undefined), new Promise((r) => setTimeout(r, CONNECT_CLEANUP_MS))]);
        throw original;
      }
      let inFlight = 0;
      let closed = false;
      const session: PgSession = {
        async query(sql, params) {
          if (closed) throw Object.assign(new Error("session closed"), { code: "08006" });
          if (inFlight > 0) throw Object.assign(new Error("query() called while a statement is outstanding"), { code: "S2_PIPELINE" });
          inFlight++;
          try { return (await client.query(sql, params)).rows; } finally { inFlight--; }
        },
        async close() {
          if (closed) return;
          closed = true;
          await client.end();      // public API only (DC-4); pg forces the stream closed if a statement is outstanding
        },
      };
      // v0.29 (IIC-0): demonstrated runtime signal only. pg's Node path upgrades `connection.stream` to a
      // tls.TLSSocket whose `encrypted` is `true`; pg-cloudflare's CloudflareSocket has no such property, so
      // there the answer is null (unknown), never inferred from the `ssl` option or from the connection working.
      session.tlsObserved = () => {
        const st = client.connection?.stream;
        const encrypted = st !== undefined && st.encrypted === true ? true : null;
        let version: string | null = null;
        if (st !== undefined && encrypted && typeof st.getProtocol === "function") { try { version = st.getProtocol() ?? null; } catch { version = null; } }
        return { encrypted, version, verified: null };
      };
      Object.defineProperty(session, RAW, { value: { client, markClosed: () => { closed = true; } }, enumerable: false });
      return session;
    },
  };
}

/** Production entry point (v0.47). If a HYPERDRIVE binding is configured it is the ONLY path: a binding without a
 *  string `connectionString` is a classified configuration denial (IIT_HYPERDRIVE_INVALID) — never a silent fallback to
 *  another credential/endpoint. Direct IIT_DB_URL with socket verify-full is used only when no binding exists. */
export function connectorFromEnv(env: Record<string, unknown>): PgConnector {
  if ("HYPERDRIVE" in env && env.HYPERDRIVE !== undefined) {
    const hd = env.HYPERDRIVE as { connectionString?: unknown } | null;
    const cs = hd && typeof hd === "object" ? hd.connectionString : undefined;
    if (typeof cs !== "string" || !cs) {
      return { async connect() { throw Object.assign(new Error("HYPERDRIVE binding is configured but has no connection string: IIT database access is disabled"), { code: "IIT_HYPERDRIVE_INVALID" }); } };
    }
    return createConnector({ connectionString: cs, tls: "hyperdrive-internal" });
  }
  const url = env.IIT_DB_URL;
  if (typeof url !== "string" || !url) {
    return { async connect() { throw Object.assign(new Error("IIT_DB_URL is not set: IIT database access is disabled"), { code: "IIT_NO_DB" }); } };
  }
  return createConnector({ connectionString: url, tls: "verify-full" });
}
