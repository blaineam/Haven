#!/usr/bin/env node
// Counting HTTP front door for the `multirelay` e2e step (spawned + killed by qa-e2e-full.mjs).
//
// Why it exists: a Haven relay writes NO logs, on purpose and without an opt-in (docs/QA.md ▸
// multirelay), and a relay that is DOWN cannot count anything anyway — yet the step has to prove
// the fleet does not stampede a dead relay. So the harness puts this in front of each CLI relay's
// HTTP interface: clients are told the proxy's port (`--http-url`), the relay itself listens on a
// loopback-only internal port, and this process counts requests per public port (timestamps and
// status codes only — nothing about who asked or for what).
//
// Kill the relay behind a port and the proxy keeps answering the TCP connect, then drops the
// socket — to a client that is indistinguishable from a relay that died mid-flight. A per-port
// throttle slows responses so a reader can be caught MID-transfer.
//
//   node Scripts/qa-relay-proxy.mjs --control 8689
//   curl -X POST 'http://127.0.0.1:8689/route?pub=8684&upstream=18684'
//   curl -X POST 'http://127.0.0.1:8689/throttle?pub=8684&bps=262144'   (0 = off)
//   curl     'http://127.0.0.1:8689/stats'
//   curl -X POST 'http://127.0.0.1:8689/quit'
//
// Exits by itself when its parent (the harness) goes away, so a crashed run cannot leave it bound.
import http from 'node:http';
import { Transform } from 'node:stream';

const arg = (name, dflt) => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : dflt;
};
const CONTROL = Number(arg('--control', 0));
const PARENT = Number(arg('--parent', process.ppid));
if (!CONTROL) { console.error('usage: qa-relay-proxy.mjs --control <port> [--parent <pid>]'); process.exit(2); }

const routes = new Map();   // pub → {upstream, server, times:[], statuses:{}, upstreamErrors, bytesDown, throttleBps}
const MAX_TIMES = 50_000;

function throttled(bps) {
  return new Transform({
    transform(chunk, _enc, cb) {
      if (!bps) return cb(null, chunk);
      const piece = 16 * 1024;
      let off = 0;
      const push = () => {
        if (off >= chunk.length) return cb();
        const part = chunk.subarray(off, off + piece);
        off += part.length;
        this.push(part);
        setTimeout(push, Math.max(1, Math.round((part.length / bps) * 1000)));
      };
      push();
    },
  });
}

function listen(pub) {
  const r = routes.get(pub);
  r.server = http.createServer((req, res) => {
    r.times.push(Date.now());
    if (r.times.length > MAX_TIMES) r.times.splice(0, r.times.length - MAX_TIMES);
    // Who is still knocking, for the harness's failure detail (which client, which call).
    (r.recent ||= []).push({ t: Date.now(), method: req.method, path: String(req.url || '').slice(0, 96),
      ua: String(req.headers['user-agent'] || '').slice(0, 48) });
    if (r.recent.length > 64) r.recent.splice(0, r.recent.length - 64);
    // In-flight requests (path only, so the harness can see a reader MID-download of one blob).
    const flight = { method: req.method, path: req.url, started: Date.now(), bytes: 0 };
    r.inflight.add(flight);
    res.on('close', () => r.inflight.delete(flight));
    const up = http.request({
      host: '127.0.0.1', port: r.upstream, method: req.method, path: req.url,
      headers: { ...req.headers, host: `127.0.0.1:${r.upstream}` },
    }, (ur) => {
      r.statuses[ur.statusCode] = (r.statuses[ur.statusCode] || 0) + 1;
      res.writeHead(ur.statusCode, ur.headers);
      ur.on('data', (c) => { r.bytesDown += c.length; flight.bytes += c.length; });
      ur.on('error', () => res.destroy());
      ur.pipe(throttled(r.throttleBps)).pipe(res);
    });
    up.on('error', () => {
      // The relay behind this door is gone (or went mid-response): drop the client's socket, the
      // same thing a dead relay does to it. Never answer on the relay's behalf.
      r.upstreamErrors += 1;
      req.socket.destroy();
    });
    req.pipe(up);
  });
  r.server.keepAliveTimeout = 5_000;
  r.server.on('error', (e) => { r.listenError = String(e.message || e); });
  r.server.listen(pub, '127.0.0.1');
}

const control = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  const pub = Number(u.searchParams.get('pub') || 0);
  const reply = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  if (u.pathname === '/stats') {
    const out = {};
    for (const [p, r] of routes) {
      out[p] = { upstream: r.upstream, hits: r.times.length, times: r.times, statuses: r.statuses,
        upstreamErrors: r.upstreamErrors, bytesDown: r.bytesDown, throttleBps: r.throttleBps, recent: r.recent || [],
        inflight: [...r.inflight].map((f) => ({ ...f, ageMs: Date.now() - f.started })),
        listening: !!r.server?.listening, listenError: r.listenError || null };
    }
    return reply(200, { pid: process.pid, ports: out });
  }
  if (req.method !== 'POST') return reply(405, { error: 'POST' });
  if (u.pathname === '/route') {
    const upstream = Number(u.searchParams.get('upstream') || 0);
    if (!pub || !upstream) return reply(400, { error: 'pub + upstream' });
    const existing = routes.get(pub);
    if (existing) { existing.upstream = upstream; return reply(200, { pub, upstream, reused: true }); }
    routes.set(pub, { upstream, times: [], statuses: {}, upstreamErrors: 0, bytesDown: 0, throttleBps: 0, inflight: new Set() });
    listen(pub);
    return setTimeout(() => reply(routes.get(pub).listenError ? 409 : 200,
      { pub, upstream, listening: !!routes.get(pub).server?.listening, error: routes.get(pub).listenError || null }), 150);
  }
  if (u.pathname === '/throttle') {
    const r = routes.get(pub);
    if (!r) return reply(404, { error: 'no such pub' });
    r.throttleBps = Number(u.searchParams.get('bps') || 0);
    return reply(200, { pub, throttleBps: r.throttleBps });
  }
  if (u.pathname === '/quit') {
    reply(200, { bye: true });
    return setTimeout(() => process.exit(0), 50);
  }
  return reply(404, { error: 'unknown' });
});
control.on('error', (e) => { console.error(`control ${CONTROL}: ${e.message}`); process.exit(3); });
control.listen(CONTROL, '127.0.0.1', () => console.log(`qa-relay-proxy control on 127.0.0.1:${CONTROL} pid ${process.pid}`));

// Never outlive the harness.
setInterval(() => {
  try { process.kill(PARENT, 0); } catch { process.exit(0); }
}, 2_000).unref();
