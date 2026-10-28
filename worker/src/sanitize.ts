// vAuto ReadAppraisalResponse → the observation body the database accepts (001 json_schemas.vauto_observation, D-7).
// Allowlist BY CONSTRUCTION: only the fields named below are ever copied; everything else in the API response is never
// read. A final self-check (assertAllowlisted) compares the produced body with a constant mirror of the database allowlist,
// so a sanitizer bug cannot emit a key the database would reject (the database enforces it again, fail closed).
// Field-name mapping (API v1.6.0 → design names), with the open points:
//   personnel.appraiser.userName → appraiser; personnel.salesPerson.userName → buyer; the API has NO closer (D-42)
//   customer phone: mobilePhone, else homePhone, else workPhone (D-43); customer.address / lien.accountNumber / lien.address
//   are NEVER copied (§7, D14); customer city/state are not in the API (absent); remarks (notes) are NOT stored until the
//   R1 decision on raw-note retention (D-44); condition flags are not mapped (no `summary` field exists — D-45).
export const VAUTO_BODY_ALLOWLIST: Record<string, Record<string, true | Record<string, true>>> = {
  vehicle:   { vin: true, year: true, make: true, model: true, series: true, trim: true, exterior_color: true, mileage: true },
  appraisal: { value: true, status: true, is_completed: true },
  personnel: { appraiser: true, buyer: true, closer: true },
  customer:  { first_name: true, last_name: true, phone: true, email: true, postal_code: true, city: true, state: true },
  title:     { region: true, name: true },
  tag:       { value: true },
  lien:      { owner: true, phone: true, payoff: true, payoff_date: true, per_diem: true },
  condition: { summary: true },
  timestamps:{ created: true, last_modified: true, completed: true },
  notes_sanitized: { labels: { label: true, value: true } },
};

type J = Record<string, unknown>;
const obj = (v: unknown): J | null => (typeof v === "object" && v !== null && !Array.isArray(v) ? (v as J) : null);
const s = (v: unknown): string | undefined => (typeof v === "string" && v.trim() !== "" ? v : undefined);
const n = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);
const b = (v: unknown): boolean | undefined => (typeof v === "boolean" ? v : undefined);
const put = (o: J, k: string, v: unknown) => { if (v !== undefined) o[k] = v; };

export interface Sanitized { id: string; body: J; completed: boolean | undefined }
export type SanitizeResult = { ok: true; value: Sanitized } | { ok: false; reason: "no_id" | "not_object" | "allowlist_violation"; detail?: string };

export function sanitizeAppraisal(raw: unknown): SanitizeResult {
  const a = obj(raw);
  if (!a) return { ok: false, reason: "not_object" };
  const id = s(a.id);
  if (!id) return { ok: false, reason: "no_id" };
  const body: J = {};
  const veh = obj(a.vehicle);
  if (veh) {
    const o: J = {};
    put(o, "vin", s(veh.vin)); put(o, "year", n(veh.year)); put(o, "make", s(veh.make)); put(o, "model", s(veh.model));
    put(o, "series", s(veh.series)); put(o, "trim", s(veh.seriesDetail)); put(o, "exterior_color", s(veh.exteriorColor)); put(o, "mileage", n(veh.odometer));
    if (Object.keys(o).length) body.vehicle = o;
  }
  const ap: J = {};
  put(ap, "value", n(obj(a.appraisalValue)?.appraisedValue)); put(ap, "status", s(a.centralizedStatus)); put(ap, "is_completed", b(a.isCompleted));
  if (Object.keys(ap).length) body.appraisal = ap;
  const per = obj(a.personnel);
  if (per) {
    const o: J = {};
    put(o, "appraiser", s(obj(per.appraiser)?.userName)); put(o, "buyer", s(obj(per.salesPerson)?.userName));
    if (Object.keys(o).length) body.personnel = o;
  }
  const cu = obj(a.customer);
  if (cu) {
    const o: J = {};
    put(o, "first_name", s(cu.firstName)); put(o, "last_name", s(cu.lastName));
    put(o, "phone", s(cu.mobilePhone) ?? s(cu.homePhone) ?? s(cu.workPhone));
    put(o, "email", s(cu.emailAddress)); put(o, "postal_code", s(cu.postalCode));
    if (Object.keys(o).length) body.customer = o;
  }
  const tr = obj(a.titleRegistration);
  if (tr) {
    const t = obj(tr.title); const g = obj(tr.tag);
    const to: J = {}; put(to, "region", s(t?.region)); put(to, "name", s(t?.name)); if (Object.keys(to).length) body.title = to;
    const go: J = {}; put(go, "value", s(g?.tag)); if (Object.keys(go).length) body.tag = go;
  }
  const li = obj(obj(a.financial)?.lien);
  if (li) {
    const o: J = {};
    put(o, "owner", s(li.owner)); put(o, "phone", s(li.phoneNumber)); put(o, "payoff", n(li.payoff)); put(o, "payoff_date", s(li.payoffDate)); put(o, "per_diem", n(li.payoffPerDiem));
    if (Object.keys(o).length) body.lien = o;
  }
  const ts: J = {};
  put(ts, "created", s(a.created)); put(ts, "last_modified", s(a.lastModified));
  if (Object.keys(ts).length) body.timestamps = ts;
  const v = assertAllowlisted(body);
  if (v) return { ok: false, reason: "allowlist_violation", detail: v };
  return { ok: true, value: { id, body, completed: b(a.isCompleted) } };
}

/** Returns the first offending path, or null. Mirrors iit.json_matches_schema: leaves are scalars; structures need a schema. */
export function assertAllowlisted(body: unknown, schema: Record<string, unknown> = VAUTO_BODY_ALLOWLIST, path = ""): string | null {
  const o = obj(body);
  if (!o) return path || "(root)";
  for (const [k, v] of Object.entries(o)) {
    const sv = schema[k];
    const p = path ? `${path}.${k}` : k;
    if (sv === undefined) return p;
    if (sv === true) { if (!(v === null || ["string", "number", "boolean"].includes(typeof v))) return p; continue; }
    if (Array.isArray(v)) { for (const e of v) { const r = assertAllowlisted(e, sv as Record<string, unknown>, p + "[]"); if (r) return r; } continue; }
    const r = assertAllowlisted(v, sv as Record<string, unknown>, p); if (r) return r;
  }
  return null;
}
