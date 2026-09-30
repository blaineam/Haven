// Screen-share frame flow: is the share still producing frames, and are they reaching the peer?
//
// Android's MediaProjection capture emits a frame only when the screen CHANGES. The old check
// ("peer's frames_decoded grew over 5s") therefore rode on incidental repaints: a still call screen
// on a loaded host read 6 → 6 and went RED with nothing wrong. The harness now makes the screen
// change on purpose (the DEBUG `screen_perturb` op repaints a counter every 200ms) and samples BOTH
// ends over the same window, so each failure names its half:
//   capture stalled — the sender captured fewer than `minCaptured` new frames despite the counter;
//   not delivered   — it captured them, but the peer decoded under `deliverRatio` of them.
// There is deliberately no SKIP path: a share that makes no frames while the screen is changing is
// broken, whatever the host load.

export const SHARE_FLOW = Object.freeze({
  windowMs: 10_000,     // sample window (the counter runs throughout)
  minCaptured: 5,       // 50 repaints in the window; even a starved emulator captures 5
  deliverRatio: 0.5,    // tolerate encoder drops (sw VP8 under load), not a dead path
});

const n = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);

/**
 * @param {{capturedStart:any, capturedEnd:any, decodedStart:any, decodedEnd:any}} s
 * @param {Partial<typeof SHARE_FLOW>} [opts]
 * @returns {{ok:boolean, verdict:'flowing'|'capture stalled'|'not delivered', captured:number, decoded:number, need:number, detail:string}}
 */
export function judgeShareFlow(s, opts = {}) {
  const o = { ...SHARE_FLOW, ...opts };
  // A counter that went BACKWARDS is a new capturer/track (a restart) — count from zero then.
  const captured = Math.max(0, n(s.capturedEnd) >= n(s.capturedStart) ? n(s.capturedEnd) - n(s.capturedStart) : n(s.capturedEnd));
  const decoded = Math.max(0, n(s.decodedEnd) >= n(s.decodedStart) ? n(s.decodedEnd) - n(s.decodedStart) : n(s.decodedEnd));
  const need = Math.max(1, Math.ceil(captured * o.deliverRatio));
  const detail = `sender +${captured} captured (${n(s.capturedStart)}→${n(s.capturedEnd)}), peer +${decoded} decoded (${n(s.decodedStart)}→${n(s.decodedEnd)}), need ≥${need}`;
  if (captured < o.minCaptured) return { ok: false, verdict: 'capture stalled', captured, decoded, need, detail };
  if (decoded < need) return { ok: false, verdict: 'not delivered', captured, decoded, need, detail };
  return { ok: true, verdict: 'flowing', captured, decoded, need, detail };
}
