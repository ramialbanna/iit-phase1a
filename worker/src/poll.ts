// Scheduled work: (1) the vAuto poll — list appraisals modified in the lookback window and hand EACH one to
// iit.ingest_vauto_observation, which stores it only if its content changed and applies the §5.3 intake rules;
// (2) iit.expire_stale_attempts — granted gate attempts with no report past the timeout become outcome_unknown.
// Idempotency: the database dedupes unchanged observations and every intake decision is keyed on the appraisal, so
// re-reading the same window every run is safe; the window overlaps on purpose (lookback), there is no checkpoint yet
// (§5.10 discovery/windows/checkpoints is an unproven strategy — D-41). Per-item failures never stop the run; the summary
// carries counts only, never row data.
import { callOne } from "./db.ts";
import { sanitizeAppraisal } from "./sanitize.ts";
import { listAppraisalsSince, type VautoDeps } from "./vauto.ts";
import type { PgConnector, WorkerConfig } from "./types.ts";

export interface PollDeps { db: PgConnector; cfg: WorkerConfig; vauto: VautoDeps; now: () => number; log: (e: Record<string, unknown>) => void }
export interface PollSummary {
  since: string; listed: number; pages: number; list_error: string | null;
  skipped_no_id: number; skipped_not_object: number; skipped_allowlist: number;
  stored: number; unchanged: number; actions: Record<string, number>; db_errors: number; budget_exhausted: boolean; elapsed_ms: number;
}

export async function runPoll(d: PollDeps): Promise<PollSummary> {
  const t0 = d.now(); const end = t0 + d.cfg.timeouts.pollBudgetMs;
  const since = new Date(t0 - d.cfg.vauto.pollLookbackMinutes * 60_000).toISOString();
  const sum: PollSummary = { since, listed: 0, pages: 0, list_error: null, skipped_no_id: 0, skipped_not_object: 0, skipped_allowlist: 0, stored: 0, unchanged: 0, actions: {}, db_errors: 0, budget_exhausted: false, elapsed_ms: 0 };
  // the poll budget is an ABSOLUTE deadline (Codex Worker v0.1 P2): the listing gets what is left minus a reserve for the
  // ingest calls, and every ingest call is bounded by the smaller of its own timeout and the time left; nothing starts after `end`.
  const reserve = 2 * d.cfg.timeouts.dbCallTimeoutMs;
  const listBudget = end - d.now() - reserve;
  const list = listBudget > 0 ? await listAppraisalsSince(d.vauto, since, listBudget) : { ok: false as const, error: "VAUTO_TIMEOUT", detail: "no_budget_for_listing", items: [], pages: 0 };
  sum.listed = list.items.length; sum.pages = list.pages; sum.list_error = list.ok ? null : `${list.error}:${list.detail}`;
  for (const raw of list.items) {
    const left = end - d.now();
    if (left <= 0) { sum.budget_exhausted = true; break; }
    const sz = sanitizeAppraisal(raw);
    if (!sz.ok) { if (sz.reason === "no_id") sum.skipped_no_id++; else if (sz.reason === "not_object") sum.skipped_not_object++; else { sum.skipped_allowlist++; d.log({ event: "poll.allowlist_violation", detail: sz.detail }); } continue; }
    const r = await callOne<Record<string, unknown>>(d.db, "SELECT iit.ingest_vauto_observation($1,$2,$3::jsonb,$4::timestamptz) AS r",
      [sz.value.id, d.cfg.vauto.accountContext, JSON.stringify(sz.value.body), new Date(d.now()).toISOString()], Math.min(d.cfg.timeouts.dbCallTimeoutMs, left), d.cfg.timeouts.cleanupTimeoutMs);
    if (!r.ok) { sum.db_errors++; if (r.error === "DB_TIMEOUT" && d.now() >= end) sum.budget_exhausted = true; d.log({ event: "poll.ingest_failed", error: r.error, detail: r.detail }); if (sum.budget_exhausted) break; continue; }
    const out = r.value;
    if (out.outcome === "unchanged") sum.unchanged++; else sum.stored++;
    const act = typeof out.action === "string" ? out.action : "unknown";
    sum.actions[act] = (sum.actions[act] ?? 0) + 1;
  }
  sum.elapsed_ms = d.now() - t0;
  d.log({ event: "poll.summary", ...sum });
  return sum;
}

export async function runExpire(db: PgConnector, cfg: WorkerConfig, log: (e: Record<string, unknown>) => void): Promise<{ ok: boolean; expired: number | null; detail?: string }> {
  const r = await callOne<number>(db, "SELECT iit.expire_stale_attempts(now()) AS r", [], cfg.timeouts.dbCallTimeoutMs, cfg.timeouts.cleanupTimeoutMs);
  if (!r.ok) { log({ event: "expire.failed", error: r.error, detail: r.detail }); return { ok: false, expired: null, detail: r.detail }; }
  log({ event: "expire.summary", expired: r.value });
  return { ok: true, expired: Number(r.value) };
}
