// IIT Phase 1a Worker — entry point. Routes: /health, POST /gate/authorize, POST /gate/report (§6.2). Scheduled: vAuto poll
// (§5.3 intake) + gate attempt expiry (§6.2). FOR LOCAL REVIEW ONLY: no deployment configuration is committed; the only
// AppSheet action in this package is "Find"; the database is reached as the tav_worker-granted login role (docs/worker.md).
import { loadConfig, validateConfig } from "./config.ts";
import { connectorFromEnv } from "./db_adapter.ts";
import { outboundGate, routeGate, type Outbound } from "./gate.ts";
import { authorizeRoute, read31, read31DepsFrom, reportRoute, type GateDeps } from "./gate_routes.ts";
import { runExpire, runPoll } from "./poll.ts";
import type { PgConnector, WorkerConfig } from "./types.ts";
import type { VautoDeps } from "./vauto.ts";

export interface Ctx { waitUntil(p: Promise<unknown>): void }
export interface Deps { db?: PgConnector; fetch?: typeof fetch; now?: () => number; log?: (e: Record<string, unknown>) => void }

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const logJson = (e: Record<string, unknown>) => console.log(JSON.stringify(e));

function safeConnectorFromEnv(env: Record<string, unknown>): PgConnector {
  try { return connectorFromEnv(env); }
  catch (e) { const err = e instanceof Error ? e : new Error(String(e)); return { async connect(): Promise<never> { throw err; } }; }
}

export async function handle(request: Request, env: Record<string, string | undefined>, deps: Deps = {}): Promise<Response> {
  const url = new URL(request.url);
  const cfg: WorkerConfig = loadConfig(env);
  const requestId = crypto.randomUUID();
  const log = deps.log ?? logJson;
  // 1. flag, then credential. ROUTES_DISABLED answers 404 for everything and touches nothing.
  const g = routeGate(cfg, request.headers.get("x-iit-credential"));
  if (!g.ok && g.reason === "ROUTES_DISABLED") return json(404, { reason: "ROUTES_DISABLED" });
  const cErr = validateConfig(cfg);
  if (cErr) return json(500, { reason: "CONFIG_INVALID", detail: cErr, request_id: requestId });
  if (url.pathname === "/health") return json(200, { ok: true });
  if (!g.ok) { log({ event: "route.denied", reason: g.reason, request_id: requestId, path: url.pathname }); return json(g.status, { reason: g.reason, request_id: requestId }); }
  if (request.method !== "POST") return json(405, { reason: "METHOD_NOT_ALLOWED", request_id: requestId });

  const db = deps.db ?? safeConnectorFromEnv(env);
  const doFetch = deps.fetch ?? fetch;
  const outboundCheck = (o: Outbound) => outboundGate(cfg, o);
  const gd: GateDeps = {
    db, cfg, now: deps.now ?? Date.now, log,
    read31: (iid, ms) => read31(read31DepsFrom(cfg, env.IIT_APPSHEET_APP_KEY ?? "", doFetch, outboundCheck), iid, ms),
  };
  const body = await request.json().catch(() => null);
  if (url.pathname === "/gate/authorize") { const r = await authorizeRoute(gd, { integration: g.integration, requestId, body }); return json(r.status, r.body); }
  if (url.pathname === "/gate/report") { const r = await reportRoute(gd, { integration: g.integration, requestId, body }); return json(r.status, r.body); }
  log({ event: "route.denied", reason: "ROUTE_NOT_FOUND", request_id: requestId, path: url.pathname, integration: g.integration });
  return json(404, { reason: "ROUTE_NOT_FOUND", request_id: requestId });
}

export async function scheduled(env: Record<string, string | undefined>, deps: Deps = {}): Promise<{ poll: unknown; expire: unknown }> {
  const cfg = loadConfig(env);
  const log = deps.log ?? logJson;
  const cErr = validateConfig(cfg);
  if (cErr) { log({ event: "scheduled.config_invalid", detail: cErr }); return { poll: null, expire: null }; }
  const db = deps.db ?? safeConnectorFromEnv(env);
  const vauto: VautoDeps = {
    fetch: deps.fetch ?? fetch, outboundCheck: (o) => outboundGate(cfg, o),
    baseUrl: cfg.vauto.baseUrl, tokenUrl: cfg.vauto.tokenUrl, entityLogicalId: cfg.vauto.entityLogicalId,
    clientId: env.VAUTO_CLIENT_ID ?? "", clientSecret: env.VAUTO_CLIENT_SECRET ?? "",
    pageSize: cfg.vauto.pageSize, timeoutMs: cfg.timeouts.vautoHttpTimeoutMs, now: deps.now ?? Date.now,
  };
  const expire = await runExpire(db, cfg, log);                     // first: cheap, and independent of vAuto availability
  const poll = await runPoll({ db, cfg, vauto, now: deps.now ?? Date.now, log });
  return { poll, expire };
}

export default {
  async fetch(request: Request, env: Record<string, string | undefined>): Promise<Response> { return handle(request, env); },
  async scheduled(_event: unknown, env: Record<string, string | undefined>, ctx: Ctx): Promise<void> { ctx.waitUntil(scheduled(env)); },
};
