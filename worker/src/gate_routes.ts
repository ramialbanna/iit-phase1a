// §6.2 route handlers: /gate/authorize and /gate/report. The Worker's job here is small and fixed:
//   1. the caller is the VERIFIED integration (route credential) — never a body field;
//   2. for authorize: perform the authoritative 3.1 read (§6.3) itself, then hand the read result and timestamp to
//      iit.authorize_and_consume, which decides (allowlist, freshness, status vocabulary, eligibility, state table);
//   3. for report: hand the outcome to iit.report_action_outcome with the verified integration.
// Every failure path answers "not allowed" (fail closed). No AppSheet write exists in this package.
import { callOne } from "./db.ts";
import { read31Status, type Read31Deps, type ReadResult } from "./read31.ts";
import type { PgConnector, WorkerConfig } from "./types.ts";

export interface GateDeps {
  db: PgConnector;
  cfg: WorkerConfig;
  read31: (iid: string, timeoutMs: number) => Promise<ReadResult>;
  now: () => number;
  log: (e: Record<string, unknown>) => void;
}

const str = (v: unknown): string | null => (typeof v === "string" && v.length > 0 ? v : null);

export interface AuthorizeInput { integration: string; requestId: string; body: unknown }

export async function authorizeRoute(d: GateDeps, inp: AuthorizeInput): Promise<{ status: number; body: Record<string, unknown> }> {
  const b = (typeof inp.body === "object" && inp.body !== null ? inp.body : {}) as Record<string, unknown>;
  const actionKey = str(b.action_key), iid = str(b.iid), action = str(b.action);
  const runRef = str(b.caller_run_ref), rowStatus = str(b.row_status), triggeredBy = str(b.triggered_by);
  if (!actionKey || !iid || !action) return { status: 400, body: { allowed: false, reason: "BAD_REQUEST", detail: "action_key, iid and action are required", request_id: inp.requestId } };

  // the authoritative read, timed; its RESULT and the time it completed are what the database judges (D-35 freshness)
  const r = await d.read31(iid, d.cfg.timeouts.httpReadTimeoutMs);
  const readAt = new Date(d.now()).toISOString();
  const readStatus: string | null = r.ok && !r.missing ? r.status : null;
  const readNote = r.ok ? (r.missing ? "missing_in_31" : "found") : `${r.error}${r.detail ? ":" + r.detail : ""}`;
  d.log({ event: "gate.read31", request_id: inp.requestId, integration: inp.integration, result: readNote, latency_ms: r.latencyMs });

  const call = await callOne<Record<string, unknown>>(d.db,
    "SELECT iit.authorize_and_consume($1,$2,$3,$4,$5,$6,$7,$8,$9::timestamptz) AS r",
    [actionKey, iid, action, inp.integration, runRef, triggeredBy, rowStatus, readStatus, readStatus === null ? null : readAt],
    d.cfg.timeouts.dbCallTimeoutMs, d.cfg.timeouts.cleanupTimeoutMs);
  if (!call.ok) {
    d.log({ event: "gate.authorize.db_failure", request_id: inp.requestId, integration: inp.integration, error: call.error, detail: call.detail });
    return { status: 502, body: { allowed: false, reason: call.error, request_id: inp.requestId } };
  }
  const out = call.value;
  d.log({ event: "gate.authorize", request_id: inp.requestId, integration: inp.integration, allowed: out.allowed === true, reason: out.reason ?? null, action_id: out.action_id ?? null });
  return { status: 200, body: { ...out, read_31: readNote, request_id: inp.requestId } };
}

export interface ReportInput { integration: string; requestId: string; body: unknown }

export async function reportRoute(d: GateDeps, inp: ReportInput): Promise<{ status: number; body: Record<string, unknown> }> {
  const b = (typeof inp.body === "object" && inp.body !== null ? inp.body : {}) as Record<string, unknown>;
  const attemptId = str(b.attempt_id), outcome = str(b.outcome), runRef = str(b.caller_run_ref);
  const evidence = typeof b.evidence === "object" && b.evidence !== null && !Array.isArray(b.evidence) ? b.evidence : {};
  if (!attemptId || !outcome) return { status: 400, body: { recorded: false, reason: "BAD_REQUEST", detail: "attempt_id and outcome are required", request_id: inp.requestId } };
  const call = await callOne<Record<string, unknown>>(d.db,
    "SELECT iit.report_action_outcome($1::uuid,$2,$3::jsonb,$4,$5) AS r",
    [attemptId, outcome, JSON.stringify(evidence), inp.integration, runRef],
    d.cfg.timeouts.dbCallTimeoutMs, d.cfg.timeouts.cleanupTimeoutMs);
  if (!call.ok) {
    d.log({ event: "gate.report.db_failure", request_id: inp.requestId, integration: inp.integration, error: call.error, detail: call.detail });
    // a server-side validation refusal (bad outcome, unknown attempt, evidence outside the allowlist) is the caller's error
    const clientError = call.error === "DB_ERROR" && /:(GATE_OUTCOME|ATTEMPT_UNKNOWN|STORAGE_POLICY)/.test(call.detail);
    return { status: clientError ? 400 : 502, body: { recorded: false, reason: clientError ? call.detail.split(":")[1] : call.error, request_id: inp.requestId } };
  }
  const out = call.value;
  d.log({ event: "gate.report", request_id: inp.requestId, integration: inp.integration, result: out.result ?? null, state: out.state ?? null });
  return { status: out.recorded === true ? 200 : 403, body: { ...out, request_id: inp.requestId } };
}

/** The 3.1 read dependencies for a request: app key from the secret, app ID from config, hosts through the outbound gate. */
export function read31DepsFrom(cfg: WorkerConfig, appKey: string, doFetch: typeof fetch, outboundCheck: Read31Deps["outboundCheck"]): Read31Deps {
  return { fetch: doFetch, outboundCheck, appKey, appId: cfg.appsheet.appId, table: cfg.appsheet.table, keyColumn: cfg.appsheet.keyColumn, statusColumn: cfg.appsheet.statusColumn };
}

export const read31 = read31Status;
