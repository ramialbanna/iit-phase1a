// Route-layer decisions (carried over from the S2 spike's gate.ts, Codex-accepted): flag → credential; outbound host allowlist.
// Pure functions: no I/O, so the contract tests exercise exactly the deployed logic.
import type { WorkerConfig } from "./types.ts";

export type RouteReason = "ROUTES_DISABLED" | "CREDENTIAL_UNKNOWN" | "HOST_NOT_ALLOWLISTED" | "APP_UNCONFIGURED";
export type Decision = { ok: true; integration: string } | { ok: false; reason: RouteReason; status: number };

/** Constant-time string compare (no early exit on the first differing byte). */
export function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

/** The authenticated integration is the NAME whose secret matches the presented credential — never a body field. */
export function identify(cfg: WorkerConfig, presented: string | null): string | null {
  if (!presented) return null;
  let found: string | null = null;
  for (const [name, secret] of Object.entries(cfg.credentials)) if (safeEqual(presented, secret)) found = name;
  return found;
}

export function routeGate(cfg: WorkerConfig, presented: string | null): Decision {
  if (!cfg.routesEnabled) return { ok: false, reason: "ROUTES_DISABLED", status: 404 };
  const integration = identify(cfg, presented);
  if (!integration) return { ok: false, reason: "CREDENTIAL_UNKNOWN", status: 401 };
  return { ok: true, integration };
}

export type Outbound = { kind: "appsheet"; host: string; appId: string } | { kind: "vauto"; url: string };

/** Any outbound call: the AppSheet app must be the configured one and every host must be allowlisted. */
export function outboundGate(cfg: WorkerConfig, o: Outbound): { ok: true } | { ok: false; reason: RouteReason } {
  if (o.kind === "appsheet") {
    if (!cfg.appsheet.appId || o.appId !== cfg.appsheet.appId) return { ok: false, reason: "APP_UNCONFIGURED" };
    return cfg.appsheet.allowedHosts.includes(o.host) ? { ok: true } : { ok: false, reason: "HOST_NOT_ALLOWLISTED" };
  }
  const host = safeHost(o.url);
  return host && cfg.appsheet.allowedHosts.includes(host) ? { ok: true } : { ok: false, reason: "HOST_NOT_ALLOWLISTED" };
}

function safeHost(u: string): string | null { try { return new URL(u).hostname; } catch { return null; } }
