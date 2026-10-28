// The authoritative 3.1 read (§6.3): AppSheet API "Find" on the registered app. Carried over from the S2 spike Worker (v0.79)
// unchanged except this header. The ONLY AppSheet action this Worker ever constructs is "Find" (the bridge is excluded: no Add,
// Edit or Delete exists anywhere in this package — asserted by test/no_writes.test.ts).
// v0.2: response structure and exact row identity are validated before any status is trusted.
// v0.3 (Codex G-B v0.2 item 5): ONE absolute deadline covers the outbound-log write, the HTTP
// request and the body handling. A log write that finishes late never triggers a request.
//   missing row (valid empty array)  -> ok, missing: true   -> SQL reason row_missing_in_31
//   status present                   -> ok, status          -> SQL decides (RR4 allowlist)
//   READ_MALFORMED | READ_DUPLICATE | READ_IDENTITY_MISMATCH | READ_ERROR | READ_TIMEOUT
// Key column "ID": app documentation export p.73 [EXP]. API shape: [DOC], UNVERIFIED (I-07).
import type { Outbound } from "./gate.ts";
import { race, TimeoutErr } from "./deadline.ts";

export interface Read31Deps {
  fetch: typeof fetch;
  outboundCheck: (o: Outbound) => { ok: true } | { ok: false; reason: string };
  appKey: string;                    // S2-only copy-app key (secret); never logged
  appId: string;                     // registered copy app ID
  table: string;                     // "01_MY CAR LIST"
  keyColumn: string;                 // "ID"
  statusColumn: string;              // "Deal Status"
  /** Outbound log row, written BEFORE the request; receives the time left. If it fails or does not
   *  finish within the deadline, no request is made. */
  beforeFetch?: (host: string, targetId: string, msLeft: number) => Promise<void>;
  now?: () => number;                // injectable clock (tests)
}

export type ReadError = "READ_TIMEOUT" | "READ_ERROR" | "READ_MALFORMED" | "READ_DUPLICATE" | "READ_IDENTITY_MISMATCH" | string;
export type ReadResult =
  | { ok: true; missing: false; status: string; latencyMs: number }
  | { ok: true; missing: true; status: null; latencyMs: number }
  | { ok: false; error: ReadError; latencyMs: number; detail?: string };

const HOST = "api.appsheet.com";
const isPlainObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

/** Pure validation of a parsed response body; exported for the tests. */
export function interpretRows(body: unknown, iid: string, keyColumn: string, statusColumn: string):
  { ok: true; missing: boolean; status: string | null } | { ok: false; error: ReadError; detail: string } {
  if (!Array.isArray(body)) return { ok: false, error: "READ_MALFORMED", detail: "body_not_array" };
  if (!body.every(isPlainObject)) return { ok: false, error: "READ_MALFORMED", detail: "row_not_object" };
  if (body.length === 0) return { ok: true, missing: true, status: null };
  if (!body.every((r) => typeof r[keyColumn] === "string")) return { ok: false, error: "READ_MALFORMED", detail: "key_missing_or_not_string" };
  if (body.some((r) => r[keyColumn] !== iid)) return { ok: false, error: "READ_IDENTITY_MISMATCH", detail: "row_with_other_id" };
  if (body.length > 1) return { ok: false, error: "READ_DUPLICATE", detail: `rows=${body.length}` };
  const only = body[0];
  if (only === undefined) return { ok: false, error: "READ_MALFORMED", detail: "row_missing_after_count" };  // unreachable after the length checks; kept for the type system
  const s = only[statusColumn];
  if (typeof s !== "string") return { ok: false, error: "READ_MALFORMED", detail: "status_missing_or_not_string" };
  return { ok: true, missing: false, status: s };
}

export async function read31Status(d: Read31Deps, iid: string, timeoutMs: number): Promise<ReadResult> {
  const now = d.now ?? Date.now;
  const t0 = now();
  const end = t0 + timeoutMs;
  const left = () => end - now();
  const lat = () => now() - t0;
  const timeout = (detail: string): ReadResult => ({ ok: false, error: "READ_TIMEOUT", latencyMs: lat(), detail });

  const gate = d.outboundCheck({ kind: "appsheet", host: HOST, appId: d.appId });
  if (!gate.ok) return { ok: false, error: gate.reason, latencyMs: 0 };   // e.g. LIVE_APP_REFUSED: before any I/O
  if (!(Number.isFinite(timeoutMs) && timeoutMs > 0)) return timeout("no_time_left");

  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), Math.max(1, timeoutMs));
  try {
    if (d.beforeFetch) {
      try { await race(d.beforeFetch(HOST, d.appId, left()), left(), "outbound_log"); }
      catch (e) { return e instanceof TimeoutErr ? timeout("outbound_log") : { ok: false, error: "READ_ERROR", latencyMs: lat(), detail: "outbound_log_failed" }; }
    }
    if (left() <= 0 || ctl.signal.aborted) return timeout("before_request");   // a late log write never leads to a request

    const body = {
      Action: "Find",
      Properties: { Selector: `Filter(${d.table}, [${d.keyColumn}] = "${iid.replace(/"/g, '""')}")` },
      Rows: [],
    };
    // v0.50 (E-5 finding): call fetch as a FREE function. `d.fetch(...)` binds `this` to the deps object and
    // Workers' native fetch then throws TypeError "Illegal invocation" (seen on production 25 Oct as READ_ERROR
    // with no detail; invisible to the mocked tests). The error, if any, is also surfaced in `detail`.
    const doFetch = d.fetch;
    const res = await race(doFetch(`https://${HOST}/api/v2/apps/${encodeURIComponent(d.appId)}/tables/${encodeURIComponent(d.table)}/Action`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ApplicationAccessKey: d.appKey },
      body: JSON.stringify(body),
      signal: ctl.signal,
    }), left(), "request");
    if (left() <= 0) return timeout("after_request");
    if (!res.ok) return { ok: false, error: "READ_ERROR", latencyMs: lat(), detail: `http_${res.status}` };
    let parsed: unknown;
    try { parsed = await race(res.json(), left(), "body"); }
    catch (e) { return e instanceof TimeoutErr ? timeout("body") : { ok: false, error: "READ_MALFORMED", latencyMs: lat(), detail: "not_json" }; }
    if (left() <= 0) return timeout("after_body");                               // clock re-checked, not just timers
    const r = interpretRows(parsed, iid, d.keyColumn, d.statusColumn);
    if (!r.ok) return { ok: false, error: r.error, latencyMs: lat(), detail: r.detail };
    return r.missing ? { ok: true, missing: true, status: null, latencyMs: lat() } : { ok: true, missing: false, status: r.status as string, latencyMs: lat() };
  } catch (e) {
    if (e instanceof TimeoutErr) return timeout(e.phase);
    const aborted = (e as { name?: string })?.name === "AbortError";
    return aborted ? timeout("aborted") : { ok: false, error: "READ_ERROR", latencyMs: lat(), detail: `exception:${String((e as { name?: string })?.name ?? "Error")}` };
  } finally {
    clearTimeout(timer);
    ctl.abort();                     // cancels any request or body still in flight after we return
  }
}
