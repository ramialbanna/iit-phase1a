// vAuto Appraisal API client (spec v1.6.0, project docs): OAuth2 client-credentials token, then GET /appraisals with an RQL
// filter on lastModified, paginated. Read-only: this client has no POST to /appraisals and never will in Phase 1a.
// UNVERIFIED against the live API (no credentials yet, I-V1..I-V3 in docs/worker.md): the token endpoint shape, the RQL
// date predicate `ge(lastModified,<iso>)`, and whether `next` is an absolute URL or a `{start},{count}` limit token. Each is
// isolated in one function below so the first live run changes one place.
import { race, TimeoutErr } from "./deadline.ts";
import type { Outbound } from "./gate.ts";

export interface VautoDeps {
  fetch: typeof fetch;
  outboundCheck: (o: Outbound) => { ok: true } | { ok: false; reason: string };
  baseUrl: string; tokenUrl: string; entityLogicalId: string;
  clientId: string; clientSecret: string;          // secrets; never logged
  pageSize: number; timeoutMs: number; maxPages?: number;
  now?: () => number;
}
export interface Page { items: unknown[]; next: string | null }
export type VautoError = "VAUTO_TIMEOUT" | "VAUTO_HTTP" | "VAUTO_MALFORMED" | "VAUTO_AUTH" | string;
export type ListResult = { ok: true; items: unknown[]; pages: number } | { ok: false; error: VautoError; detail: string; items: unknown[]; pages: number };

const ACCEPT = "application/vnd.coxauto.v1+json";
const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

/** I-V1: RQL date predicate. The spec shows `eq(vehicle.make,Toyota)`; the comparison operator for timestamps is assumed `ge`. */
export function rqlSince(sinceIso: string): string { return `ge(lastModified,${sinceIso})`; }
/** I-V3: page cursor. `next` is treated as an absolute URL when it parses as one, else as a `{start},{count}` limit token. */
export function nextUrl(baseUrl: string, firstUrl: string, next: string | null): string | null {
  if (!next) return null;
  try { const u = new URL(next); return u.toString(); } catch { /* not a URL */ }
  const u = new URL(firstUrl); u.searchParams.set("limit", next); return u.toString();
}

async function fetchJson(d: VautoDeps, url: string, init: RequestInit, msLeft: number): Promise<{ ok: true; status: number; body: unknown } | { ok: false; error: VautoError; detail: string }> {
  const gate = d.outboundCheck({ kind: "vauto", url });
  if (!gate.ok) return { ok: false, error: gate.reason, detail: "outbound_gate" };
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), Math.max(1, msLeft));
  try {
    const doFetch = d.fetch;                                   // free function (S2 E-5 finding: never d.fetch(...))
    const res = await race(doFetch(url, { ...init, signal: ctl.signal }), msLeft, "request");
    let body: unknown = null;
    try { body = await race(res.json(), Math.max(1, msLeft), "body"); } catch (e) { if (e instanceof TimeoutErr) return { ok: false, error: "VAUTO_TIMEOUT", detail: "body" }; body = null; }
    if (res.status === 401 || res.status === 403) return { ok: false, error: "VAUTO_AUTH", detail: `http_${res.status}` };
    if (!res.ok) return { ok: false, error: "VAUTO_HTTP", detail: `http_${res.status}` };
    return { ok: true, status: res.status, body };
  } catch (e) {
    if (e instanceof TimeoutErr || (e as { name?: string })?.name === "AbortError") return { ok: false, error: "VAUTO_TIMEOUT", detail: "request" };
    return { ok: false, error: "VAUTO_HTTP", detail: `exception:${String((e as { name?: string })?.name ?? "Error")}` };
  } finally { clearTimeout(timer); ctl.abort(); }
}

/** I-V2: OAuth2 client credentials (RFC 6749 §4.4), form-encoded, scope va.appraisal.read. */
export async function getToken(d: VautoDeps, msLeft: number): Promise<{ ok: true; token: string } | { ok: false; error: VautoError; detail: string }> {
  if (!d.tokenUrl || !d.clientId || !d.clientSecret) return { ok: false, error: "VAUTO_AUTH", detail: "unconfigured" };
  const form = new URLSearchParams({ grant_type: "client_credentials", scope: "va.appraisal.read" });
  const basic = btoa(`${d.clientId}:${d.clientSecret}`);
  const r = await fetchJson(d, d.tokenUrl, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", Authorization: `Basic ${basic}` }, body: form.toString() }, msLeft);
  if (!r.ok) return r;
  const tok = isObj(r.body) ? r.body.access_token : undefined;
  if (typeof tok !== "string" || !tok) return { ok: false, error: "VAUTO_MALFORMED", detail: "no_access_token" };
  return { ok: true, token: tok };
}

/** Appraisals modified since `sinceIso`, every page, oldest first. Partial results are returned WITH the error when a later
 *  page fails, so the caller can ingest what arrived (the database dedupes) and report the gap. */
export async function listAppraisalsSince(d: VautoDeps, sinceIso: string, budgetMs: number): Promise<ListResult> {
  const now = d.now ?? Date.now; const end = now() + budgetMs; const left = () => end - now();
  const items: unknown[] = []; let pages = 0;
  if (!d.baseUrl || !d.entityLogicalId) return { ok: false, error: "VAUTO_AUTH", detail: "unconfigured", items, pages };
  const tok = await getToken(d, Math.min(d.timeoutMs, left()));
  if (!tok.ok) return { ok: false, error: tok.error, detail: tok.detail, items, pages };
  const first = new URL(`${d.baseUrl.replace(/\/$/, "")}/appraisals`);
  first.searchParams.set("entityLogicalId", d.entityLogicalId);
  first.searchParams.set("filter", rqlSince(sinceIso));
  first.searchParams.set("sort", "lastModified");
  first.searchParams.set("limit", `1,${d.pageSize}`);
  let url: string | null = first.toString();
  const maxPages = d.maxPages ?? 50;
  while (url && pages < maxPages) {
    if (left() <= 0) return { ok: false, error: "VAUTO_TIMEOUT", detail: "budget", items, pages };
    const r = await fetchJson(d, url, { method: "GET", headers: { Accept: ACCEPT, Authorization: `Bearer ${tok.token}`, "X-CoxAuto-ConsistentRead": "true" } }, Math.min(d.timeoutMs, left()));
    if (!r.ok) return { ok: false, error: r.error, detail: `page_${pages + 1}:${r.detail}`, items, pages };
    if (!isObj(r.body) || !Array.isArray(r.body.items)) return { ok: false, error: "VAUTO_MALFORMED", detail: `page_${pages + 1}:items_not_array`, items, pages };
    items.push(...r.body.items); pages++;
    url = nextUrl(d.baseUrl, first.toString(), typeof r.body.next === "string" ? r.body.next : null);
  }
  if (url) return { ok: false, error: "VAUTO_HTTP", detail: "max_pages", items, pages };
  return { ok: true, items, pages };
}
