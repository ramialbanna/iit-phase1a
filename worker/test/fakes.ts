// Test doubles for the Worker's decision logic. They prove routing, argument passing and failure handling — NOT database
// behaviour, which is proven by the SQL suites under supabase/tests against real Postgres.
import type { PgConnector, PgSession } from "../src/types.ts";

export type Script = (sql: string, params?: unknown[]) => Record<string, unknown>[] | Error | Promise<Record<string, unknown>[] | Error>;

export class FakeSession implements PgSession {
  log: { sql: string; params: unknown[] | undefined }[] = [];
  closed = false;
  private script: Script;
  constructor(script: Script) { this.script = script; }
  async query(sql: string, params?: unknown[]) {
    if (this.closed) throw Object.assign(new Error("session closed"), { code: "08006" });
    this.log.push({ sql: sql.replace(/\s+/g, " ").trim(), params });
    const r = await this.script(sql, params);
    if (r instanceof Error) throw r;
    return r;
  }
  async close() { this.closed = true; }
}
export class FakeConnector implements PgConnector {
  sessions: FakeSession[] = [];
  private script: Script; failConnect: boolean; connectDelayMs: number;
  constructor(script: Script, failConnect = false, connectDelayMs = 0) { this.script = script; this.failConnect = failConnect; this.connectDelayMs = connectDelayMs; }
  async connect() {
    if (this.connectDelayMs) await new Promise((r) => setTimeout(r, this.connectDelayMs));
    if (this.failConnect) throw Object.assign(new Error("connect failed"), { code: "ECONNREFUSED" });
    const s = new FakeSession(this.script); this.sessions.push(s); return s;
  }
  get calls() { return this.sessions.flatMap((s) => s.log); }
  get allClosed() { return this.sessions.every((s) => s.closed); }
}
export const delay = <T>(ms: number, v: T) => new Promise<T>((r) => setTimeout(() => r(v), ms));
export const http = (status: number, body: unknown) => (async () => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })) as typeof fetch;

export const ENV: Record<string, string> = {
  IIT_ROUTES_ENABLED: "true", IIT_CRED_APPSHEET_31: "secret-a", IIT_CRED_ZAP_TEXTS: "secret-z",
  IIT_APPSHEET_APP_ID: "app-1", IIT_APPSHEET_APP_KEY: "k", IIT_ALLOW_EXTERNAL_HOSTS: "api.appsheet.com,vauto.example",
  VAUTO_BASE_URL: "https://vauto.example/api", VAUTO_TOKEN_URL: "https://vauto.example/oauth/token", VAUTO_ENTITY_LOGICAL_ID: "ent-1",
  VAUTO_CLIENT_ID: "cid", VAUTO_CLIENT_SECRET: "csec",
};
