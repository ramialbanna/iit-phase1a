// IIT Phase 1a Worker — shared types. The database-session surface is carried over from the S2 spike Worker (v0.79):
// one pinned session, one statement in flight at a time (A2), public close() only.

export interface PgSession {
  query(sql: string, params?: unknown[]): Promise<Record<string, unknown>[]>;
  close(): Promise<void>;
  tlsObserved?(): TlsObserved;
}
export interface TlsObserved { encrypted: boolean | null; version: string | null; verified: null }
export interface PgConnector { connect(): Promise<PgSession> }

/** Fail-closed accessor for a query that must return exactly one row. */
export function onlyRow(rows: Record<string, unknown>[], what: string): Record<string, unknown> {
  const row = rows[0];
  if (row === undefined || rows.length !== 1) {
    throw Object.assign(new Error(`${what}: expected exactly one row, got ${rows.length}`), { code: "IIT_ROW_SHAPE" });
  }
  return row;
}

export interface Timeouts {
  cleanupTimeoutMs: number;      // bound on close() after a failure
  httpReadTimeoutMs: number;     // the 3.1 read (AbortController)
  dbCallTimeoutMs: number;       // one database function call (connect + statement)
  vautoHttpTimeoutMs: number;    // one vAuto API request
  pollBudgetMs: number;          // whole scheduled poll run
}

export interface WorkerConfig {
  routesEnabled: boolean;                    // IIT_ROUTES_ENABLED === "true" exactly; otherwise every route is 404
  credentials: Record<string, string>;       // integration name → credential (IIT_CRED_<NAME> secrets); names only are logged
  appsheet: { appId: string; table: string; keyColumn: string; statusColumn: string; allowedHosts: string[] };
  vauto: { baseUrl: string; tokenUrl: string; entityLogicalId: string; accountContext: string; pollLookbackMinutes: number; pageSize: number };
  timeouts: Timeouts;
}

/** Result of one database function call, kept generic: the SQL function's jsonb is passed through untouched. */
export type DbCall<T> = { ok: true; value: T } | { ok: false; error: "DB_TIMEOUT" | "DB_ERROR" | "DB_SHAPE"; detail: string };
