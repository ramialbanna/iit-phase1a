// Parses the Worker environment. Deny-by-default: anything missing is empty/false/zero and the dependent path denies.
// Secrets (credentials, keys, DB URL) are never logged; only credential NAMES appear anywhere.
import type { Timeouts, WorkerConfig } from "./types.ts";

function list(v: string | undefined): string[] { return (v ?? "").split(",").map((s) => s.trim()).filter(Boolean); }
function int(v: string | undefined, dflt: number): number { const n = Number(v ?? dflt); return Number.isFinite(n) ? n : NaN; }

export function loadConfig(env: Record<string, string | undefined>): WorkerConfig {
  const creds: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) if (k.startsWith("IIT_CRED_") && v) creds[k.slice("IIT_CRED_".length).toLowerCase()] = v;
  return {
    routesEnabled: env.IIT_ROUTES_ENABLED === "true",
    credentials: creds,
    appsheet: {
      appId: env.IIT_APPSHEET_APP_ID ?? "",
      table: env.IIT_APPSHEET_TABLE ?? "01_MY CAR LIST",
      keyColumn: "ID", statusColumn: "Deal Status",
      allowedHosts: list(env.IIT_ALLOW_EXTERNAL_HOSTS),           // must contain api.appsheet.com (and the vAuto hosts) to read anything
    },
    vauto: {
      baseUrl: env.VAUTO_BASE_URL ?? "", tokenUrl: env.VAUTO_TOKEN_URL ?? "",
      entityLogicalId: env.VAUTO_ENTITY_LOGICAL_ID ?? "",
      accountContext: env.VAUTO_ENTITY_LOGICAL_ID ?? "",           // external_references.account_context (collision guard)
      pollLookbackMinutes: int(env.VAUTO_POLL_LOOKBACK_MINUTES, 180),
      pageSize: int(env.VAUTO_PAGE_SIZE, 100),
    },
    timeouts: {
      cleanupTimeoutMs: int(env.IIT_CLEANUP_TIMEOUT_MS, 1000),
      httpReadTimeoutMs: int(env.IIT_HTTP_READ_TIMEOUT_MS, 3000),
      dbCallTimeoutMs: int(env.IIT_DB_CALL_TIMEOUT_MS, 5000),
      vautoHttpTimeoutMs: int(env.VAUTO_HTTP_TIMEOUT_MS, 8000),
      pollBudgetMs: int(env.VAUTO_POLL_BUDGET_MS, 25000),
    },
  };
}

/** Every timeout finite, positive, integral; the 3.1 read must fit inside one gate call's budget with room for the DB call. */
export function validateConfig(c: WorkerConfig): string | null {
  const t: Timeouts = c.timeouts;
  for (const [k, v] of Object.entries(t)) if (!(Number.isFinite(v) && Number.isInteger(v) && v > 0)) return `${k} must be a finite positive integer (got ${String(v)})`;
  if (!(t.vautoHttpTimeoutMs < t.pollBudgetMs)) return "vAuto HTTP timeout must be below the poll budget";
  if (!(c.vauto.pollLookbackMinutes > 0 && Number.isInteger(c.vauto.pollLookbackMinutes))) return "poll lookback must be a positive integer";
  if (!(c.vauto.pageSize > 0 && c.vauto.pageSize <= 100)) return "vAuto page size must be 1..100 (API max)";
  // duplicate credential VALUES would make the caller's identity ambiguous (Codex Worker v0.1 P1): refused at load, so every
  // route answers CONFIG_INVALID until the secrets are distinct. Only the NAMES are reported.
  const seen = new Map<string, string>();
  for (const [name, secret] of Object.entries(c.credentials)) {
    const other = seen.get(secret);
    if (other !== undefined) return `credentials ${other} and ${name} share one secret value`;
    seen.set(secret, name);
  }
  if (c.vauto.baseUrl && !c.vauto.baseUrl.startsWith("https://")) return "VAUTO_BASE_URL must be https";
  if (c.vauto.tokenUrl && !c.vauto.tokenUrl.startsWith("https://")) return "VAUTO_TOKEN_URL must be https";
  return null;
}
