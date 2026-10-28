// One database function call = one fresh session, one statement, bounded by dbCallTimeoutMs, then close. No transaction
// management here: every iit.* function the Worker calls is atomic on the server (SECURITY DEFINER, one statement).
// Failure semantics (fail closed, RR2): a timeout or lost response AFTER the statement was sent means the server may have
// committed (e.g. a grant) while the caller gets DB_TIMEOUT. The route then answers 502 (= deny); a committed grant stays
// outstanding, a retry gets in_progress, and the 10-minute expiry turns it into outcome_unknown + work item (§6.2).
import { race, TimeoutErr } from "./deadline.ts";
import { onlyRow, type DbCall, type PgConnector, type PgSession } from "./types.ts";

export async function boundedClose(s: PgSession, ms: number): Promise<void> {
  await Promise.race([s.close().catch(() => undefined), new Promise<void>((r) => setTimeout(r, ms))]);
}

/** Calls `SELECT <fn>(...) AS r` and returns the single `r` value. */
export async function callOne<T = unknown>(db: PgConnector, sql: string, params: unknown[], timeoutMs: number, cleanupMs: number): Promise<DbCall<T>> {
  const end = Date.now() + timeoutMs;
  let s: PgSession;
  try { s = await race(db.connect(), timeoutMs, "connect", (late) => { void boundedClose(late, cleanupMs); }); }
  catch (e) { return e instanceof TimeoutErr ? { ok: false, error: "DB_TIMEOUT", detail: "connect" } : { ok: false, error: "DB_ERROR", detail: errCode(e) }; }
  try {
    const rows = await race(s.query(sql, params), end - Date.now(), "statement");
    const row = onlyRow(rows, sql.slice(0, 40));
    return { ok: true, value: row.r as T };
  } catch (e) {
    if (e instanceof TimeoutErr) return { ok: false, error: "DB_TIMEOUT", detail: e.phase };
    if ((e as { code?: string })?.code === "IIT_ROW_SHAPE") return { ok: false, error: "DB_SHAPE", detail: String((e as Error).message) };
    return { ok: false, error: "DB_ERROR", detail: errCode(e) };
  } finally { await boundedClose(s, cleanupMs); }
}

/** Only the SQLSTATE / error code and the leading token of the message (e.g. `RELEASE_REFUSED`) leave this module — never
 *  parameter values. */
export function errCode(e: unknown): string {
  const code = (e as { code?: string })?.code;
  const msg = e instanceof Error ? e.message : String(e);
  const head = msg.match(/^[A-Z0-9_]{3,}/)?.[0] ?? "error";
  return `${code ?? "?"}:${head}`;
}
