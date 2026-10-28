// Absolute-deadline helpers (v0.3, Codex G-B v0.2 item 5). Timer scheduling alone is not trusted:
// callers re-check the injected clock after every awaited operation.
export class TimeoutErr extends Error {
  phase: string;
  constructor(phase: string) { super(`timeout during ${phase}`); this.phase = phase; this.name = "TimeoutErr"; }
}

/** Rejects with TimeoutErr if p has not settled within ms (or at once if ms <= 0). If p settles
 *  later, onLate runs (dispose a late connection, ignore a late log write, ...). */
export function race<T>(p: Promise<T>, ms: number, phase: string, onLate?: (v: T) => void): Promise<T> {
  if (!(ms > 0)) { p.then((v) => onLate?.(v), () => undefined); return Promise.reject(new TimeoutErr(phase)); }
  return new Promise<T>((resolve, reject) => {
    let done = false;
    const timer = setTimeout(() => { if (!done) { done = true; reject(new TimeoutErr(phase)); } }, ms);
    p.then((v) => { if (done) { onLate?.(v); return; } done = true; clearTimeout(timer); resolve(v); },
           (e) => { if (done) return; done = true; clearTimeout(timer); reject(e); });
  });
}
