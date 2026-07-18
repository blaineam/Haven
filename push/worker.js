// Haven push relay — a "blind" APNs sender on Cloudflare Workers.
//
// It knows only `nodeId → device token` and forwards ENCRYPTED payloads; it never sees
// message content (the app's Notification Service Extension decrypts on-device). APNs is
// free; this Worker is free to 100k req/day, then ~$5/mo for 10M. No third-party SDK.
//
// Secrets (set with `wrangler secret put …`):
//   APNS_KEY      – the .p8 AuthKey PEM contents (-----BEGIN PRIVATE KEY----- … )
//   APNS_KEY_ID   – the 10-char Key ID
//   APNS_TEAM_ID  – your Apple Team ID (8ZVSPZYSVF)
// Vars (in wrangler.toml):
//   APNS_TOPIC = "com.blaineam.kith"
//   APNS_HOST  = "api.push.apple.com"   (use api.sandbox.push.apple.com for dev builds)
// Binding: KV namespace `TOKENS`.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST") return json({ ok: true, service: "haven-push" });

    try {
      if (url.pathname === "/register") {
        // A node id can have MULTIPLE devices (multi-device / linked devices) — keep a list of
        // tokens, not one, so a push reaches every device on that identity.
        const { nodeId, token, sandbox, platform, ts, sig } = await request.json();
        if (!nodeId || !hexToken(token)) return json({ error: "nodeId + token required" }, 400);
        // The registration must be signed by the identity (audit F5) — stops anyone registering
        // their token under someone else's node id (token hijack / eviction of the real device).
        if (!(await verifyReg(nodeId, token, ts, sig))) return json({ error: "unauthorized" }, 401);
        const rec = (await env.TOKENS.get(nodeId, "json")) || { tokens: [] };
        const tokens = (rec.tokens || (rec.token ? [{ token: rec.token, sandbox: rec.sandbox }] : []))
          .filter((t) => t.token !== token);
        // platform ("ios" | "macos") lets the push step pick alert+NSE (iOS) vs a silent
        // content-available push the macOS app decrypts in-process (macOS has no NSE).
        tokens.push({ token, sandbox: !!sandbox, platform: platform || "ios" });
        if (tokens.length > 10) tokens.splice(0, tokens.length - 10);   // cap per identity
        await env.TOKENS.put(nodeId, JSON.stringify({ tokens }));
        return json({ ok: true, devices: tokens.length });
      }

      if (url.pathname === "/register-owner") {
        // A member who shares an S3 bucket as their circle's mailbox registers here, so the cron
        // can nudge them (silently) to re-mint fresh pre-signed URLs before the old ones expire.
        const { nodeId, token, sandbox, ts, sig } = await request.json();
        if (!nodeId || !hexToken(token)) return json({ error: "nodeId + token required" }, 400);
        if (!(await verifyReg(nodeId, token, ts, sig))) return json({ error: "unauthorized" }, 401);
        await env.TOKENS.put(`owner:${nodeId}`, JSON.stringify({ token, sandbox: !!sandbox }));
        return json({ ok: true });
      }

      if (url.pathname === "/register-voip") {
        // PushKit VoIP token (separate from the regular APNs token) so calls can ring from a
        // fully-killed/locked device. A node id (ACCOUNT id) can have MULTIPLE iOS devices —
        // keep a LIST like /register does. The old single-record shape silently broke ringing
        // for every device except whichever registered last (each launch of any linked device
        // clobbered the one slot), which reads as "calls never ring in the background".
        const { nodeId, token, sandbox, ts, sig } = await request.json();
        if (!nodeId || !hexToken(token)) return json({ error: "nodeId + token required" }, 400);
        if (!(await verifyReg(nodeId, token, ts, sig))) return json({ error: "unauthorized" }, 401);
        const rec = (await env.TOKENS.get(`voip:${nodeId}`, "json")) || {};
        const tokens = (rec.tokens || (rec.token ? [{ token: rec.token, sandbox: rec.sandbox }] : []))
          .filter((t) => t.token !== token);
        tokens.push({ token, sandbox: !!sandbox });
        if (tokens.length > 5) tokens.splice(0, tokens.length - 5);   // cap per identity
        await env.TOKENS.put(`voip:${nodeId}`, JSON.stringify({ tokens }));
        return json({ ok: true, devices: tokens.length });
      }

      if (url.pathname === "/call") {
        // Blind VoIP wake for an incoming call. `ciphertext` is the caller's name SEALED to the
        // callee — the worker can't read it; the device's PushKit handler decrypts it and calls
        // reportNewIncomingCall. The worker is NOT in the call: signaling rides sealed iroh,
        // media is P2P DTLS-SRTP. This is a one-shot doorbell.
        const { nodeId, ciphertext } = await request.json();
        if (!nodeId) return json({ error: "nodeId required" }, 400);
        if (await rateLimited(env, request, "call")) return json({ ok: true }, 200);
        const jwt = await providerToken(env);
        // A call push that lands after the caller gave up (~30s) must NOT ring a ghost call —
        // tell APNs to drop it instead of storing-and-forwarding it minutes later.
        const expiry = String(Math.floor(Date.now() / 1000) + 45);
        const rec = await env.TOKENS.get(`voip:${nodeId}`, "json");
        // Every registered iOS device of this identity (list; legacy single-record migrated).
        const voip = rec ? (rec.tokens || (rec.token ? [{ token: rec.token, sandbox: rec.sandbox }] : [])) : [];
        const survivors = [];
        let anyOk = false;
        for (const t of voip) {
          const host = t.sandbox ? "api.sandbox.push.apple.com" : (env.APNS_HOST || "api.push.apple.com");
          const res = await fetch(`https://${host}/3/device/${t.token}`, {
            method: "POST",
            headers: {
              authorization: `bearer ${jwt}`,
              "apns-topic": `${env.APNS_TOPIC}.voip`,   // VoIP pushes use the <bundleId>.voip topic
              "apns-push-type": "voip",
              "apns-priority": "10",
              "apns-expiration": expiry,
            },
            body: JSON.stringify({ e: ciphertext || "" }),
          });
          if (res.ok) anyOk = true;
          else await logApns("call/voip", res, t.token);
          if (res.status !== 410) survivors.push(t);   // drop tokens APNs says are dead
        }
        if (survivors.length !== voip.length) {
          if (survivors.length) await env.TOKENS.put(`voip:${nodeId}`, JSON.stringify({ tokens: survivors }));
          else await env.TOKENS.delete(`voip:${nodeId}`);
        }
        // FALLBACK: no live VoIP token (registration failed / old build / token pruned) → ring
        // the regular alert path loudly instead of silently doing nothing. The NSE decrypts the
        // same sealed {t,h} payload into "Incoming call"; macOS gets its usual silent+decrypt.
        if (!anyOk) {
          const nrec = await env.TOKENS.get(nodeId, "json");
          const ntokens = nrec ? (nrec.tokens || (nrec.token ? [{ token: nrec.token, sandbox: nrec.sandbox }] : [])) : [];
          for (const t of ntokens) {
            const host = t.sandbox ? "api.sandbox.push.apple.com" : (env.APNS_HOST || "api.push.apple.com");
            const quiet = t.platform === "macos";
            const payload = quiet
              ? { aps: { "content-available": 1 }, ...(ciphertext && ciphertext !== "_" ? { e: ciphertext } : {}), call: 1 }
              : {
                  aps: {
                    "mutable-content": 1,
                    alert: { title: "Haven", body: "Incoming call" },
                    sound: "default",
                    "interruption-level": "time-sensitive",
                  },
                  ...(ciphertext && ciphertext !== "_" ? { e: ciphertext } : {}),
                  call: 1,
                };
            const res = await fetch(`https://${host}/3/device/${t.token}`, {
              method: "POST",
              headers: {
                authorization: `bearer ${jwt}`,
                "apns-topic": env.APNS_TOPIC,
                "apns-push-type": quiet ? "background" : "alert",
                "apns-priority": quiet ? "5" : "10",
                "apns-expiration": expiry,
              },
              body: JSON.stringify(payload),
            });
            if (res.ok) anyOk = true;
            else await logApns("call/alert-fallback", res, t.token);
          }
        }
        // Uniform response whether or not the node is registered (audit F6): a distinguishable
        // error would let anyone enumerate which node-ids are real, call-capable Haven users.
        return json({ ok: true }, 200);
      }

      if (url.pathname === "/flag") {
        // Moderation ledger (App Review 1.2 "notify the developer"). Haven is E2E — the developer
        // sees NO content, ever. An explicit REPORT appends one row: subject, action, category.
        //
        // Three deliberate limits, all from audit F1:
        //   * `action` is report-ONLY. A block is a private, local act; it must not be expressible
        //     here at all, so an old client that still pings on block is refused by the server.
        //   * The row carries NO actor — not even hashed. Node ids are enumerable (this same KV is
        //     full of them), so any deterministic function of the actor that the worker can compute
        //     is one the operator can invert. Not storing it is the only honest way to not hold the
        //     "A reported B" graph edge the mandate forbids.
        //   * Rows expire (90d). A forgery-resistant record is still not a permanent one.
        const { actor, subject, action, reason, ts, sig } = await request.json();
        if (action !== "report") return json({ error: "bad action" }, 400);
        if (!/^[0-9a-f]{8,64}$/.test(actor || "") || !/^[0-9a-f]{8,64}$/.test(subject || ""))
          return json({ error: "actor + subject node hex required" }, 400);
        const category = String(reason || "").slice(0, 64);   // category only — free text stays in the circle
        // The reporter must prove the identity key (audit F1): TERMS.md attaches real consequences to
        // these rows, so an unauthenticated POST must not be able to plant one against anyone. Same
        // Ed25519-over-a-domain-string check the /register routes use; the signed material binds
        // subject + action + category (not just the actor), so a captured flag cannot be re-aimed.
        // The 5-min window in verifyReg plus the ts-derived key below make a replay a no-op write.
        if (!(await verifyReg(actor, flagMaterial(subject, action, category), ts, sig)))
          return json({ error: "unauthorized" }, 401);
        if (await rateLimited(env, request, "flag")) return json({ ok: true }, 200);
        // Key is derived from the SIGNED ts + the signature, never a fresh uuid: re-POSTing a captured
        // flag inside the freshness window rewrites the identical row instead of inflating the count.
        const key = `ledger:${new Date(Number(ts) * 1000).toISOString()}:${await sigTag(sig)}`;
        await env.TOKENS.put(key, JSON.stringify({ subject, action, reason: category }),
                             { expirationTtl: 90 * 24 * 3600 });
        return json({ ok: true });
      }

      if (url.pathname === "/notify") {
        // ciphertext = base64 of the circle-sealed banner the NSE decrypts.
        // event = base64 of the sealed circle event itself (push-inline sync).
        // silent = true → a content-available push with no banner (used to sync an authored
        //          event to the sender's OWN other devices, so it doesn't self-notify).
        // The relay reads neither `e` nor `ev` (both ciphertext).
        const { nodeId, ciphertext, event, silent } = await request.json();
        if (!nodeId || (!silent && !ciphertext)) return json({ error: "nodeId required" }, 400);
        if (await rateLimited(env, request, "notify")) return json({ ok: true }, 200);
        const rec = await env.TOKENS.get(nodeId, "json");
        const tokens = rec ? (rec.tokens || (rec.token ? [{ token: rec.token, sandbox: rec.sandbox }] : [])) : [];
        // Uniform response for an unknown node (audit F6) — no existence oracle.
        if (!tokens.length) return json({ ok: true }, 200);

        const jwt = await providerToken(env);
        // Payload is per-token: macOS has no Notification Service Extension, so instead of an
        // alert+mutable-content push (which the iOS NSE rewrites in place), we send macOS a
        // SILENT content-available push carrying `e` — the running Mac app decrypts it
        // in-process and posts its own local notification. iOS keeps the NSE path.
        const bodyFor = (platform) => {
          const isMac = platform === "macos";
          const payload = (silent || isMac)
            ? { aps: { "content-available": 1 }, ...(ciphertext ? { e: ciphertext } : {}) }
            : {
                aps: {
                  "mutable-content": 1,                              // triggers the on-device NSE
                  alert: { title: "Haven", body: "New activity" },  // fallback if the NSE can't decrypt
                  sound: "default",
                },
                e: ciphertext,
              };
          // Inline the sealed event only if the whole payload stays under APNs' 4KB limit.
          if (event && JSON.stringify(payload).length + event.length < 3900) payload.ev = event;
          return JSON.stringify(payload);
        };

        const survivors = [];
        let anyOk = false;
        for (const t of tokens) {
          const host = t.sandbox ? "api.sandbox.push.apple.com" : (env.APNS_HOST || "api.push.apple.com");
          // macOS uses a silent (background) push so the app can decrypt + notify itself.
          const quiet = silent || t.platform === "macos";
          const res = await fetch(`https://${host}/3/device/${t.token}`, {
            method: "POST",
            headers: {
              authorization: `bearer ${jwt}`,
              "apns-topic": env.APNS_TOPIC,
              "apns-push-type": quiet ? "background" : "alert",
              "apns-priority": quiet ? "5" : "10",
            },
            body: bodyFor(t.platform),
          });
          if (res.ok) anyOk = true;
          else await logApns(`notify/${t.platform || "ios"}`, res, t.token);
          if (res.status !== 410) survivors.push(t);   // drop tokens APNs says are dead
        }
        if (survivors.length !== tokens.length) {
          if (survivors.length) await env.TOKENS.put(nodeId, JSON.stringify({ tokens: survivors }));
          else await env.TOKENS.delete(nodeId);
        }
        return json({ ok: anyOk, devices: tokens.length }, anyOk ? 200 : 502);
      }

      return json({ error: "not found" }, 404);
    } catch (e) {
      return json({ error: String(e) }, 500);
    }
  },

  // Cron trigger (see wrangler.toml): nudge every S3-bucket owner with a SILENT push so their
  // app wakes in the background and re-mints fresh pre-signed URLs for their circles — keeping
  // the mailbox alive without the user thinking about it. Best-effort (iOS throttles silent
  // pushes); the app also re-mints on launch and schedules a local fallback reminder.
  async scheduled(event, env, ctx) {
    ctx.waitUntil((async () => {
      const jwt = await providerToken(env);
      let cursor;
      do {
        const page = await env.TOKENS.list({ prefix: "owner:", cursor });
        cursor = page.list_complete ? undefined : page.cursor;
        for (const k of page.keys) {
          const rec = await env.TOKENS.get(k.name, "json");
          if (!rec || !rec.token) continue;
          const host = rec.sandbox ? "api.sandbox.push.apple.com" : (env.APNS_HOST || "api.push.apple.com");
          const res = await fetch(`https://${host}/3/device/${rec.token}`, {
            method: "POST",
            headers: {
              authorization: `bearer ${jwt}`,
              "apns-topic": env.APNS_TOPIC,
              "apns-push-type": "background",
              "apns-priority": "5",
            },
            body: JSON.stringify({ aps: { "content-available": 1 }, remint: 1 }),
          });
          if (res.status === 410) await env.TOKENS.delete(k.name);   // owner's token died
        }
      } while (cursor);
    })());
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}

/// The material a /flag signature covers, slotted into verifyReg's `token` position. The core FFI
/// exposes exactly one purpose-specific signer (`sign_push_registration`) and deliberately no raw
/// signing oracle (audit H3), so /flag reuses it rather than growing a second one — and the two
/// message spaces are kept provably disjoint by `hexToken` below: a real APNs/PushKit token is always
/// hex, and this string never is. Subject is hex and action is a fixed word, so only `reason` is free
/// and it sits at the tail — the mapping from fields to string is injective, no delimiter ambiguity.
/// (Cleaner long-term: a `sign_moderation_flag` with its own `haven-push-flag-v1` tag in core.)
function flagMaterial(subject, action, reason) {
  return `flag-v1:${subject}:${action}:${reason}`;
}

/// Device tokens are hex, always (both platforms format them `%02x`). Enforcing that is what keeps a
/// /flag signature from being replayable as a registration — see flagMaterial.
const hexToken = (t) => /^[0-9a-f]{8,256}$/.test(t || "");

/// Short, non-invertible tag for a ledger key. The signature is never stored, so its hash reveals
/// nothing about the reporter — it only makes a replayed flag idempotent.
async function sigTag(sigB64) {
  const d = await crypto.subtle.digest("SHA-256", base64ToBytes(sigB64));
  return [...new Uint8Array(d).slice(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// Verify a signed registration (audit F5): the node id IS the identity's Ed25519 public key, so the
/// worker checks the Ed25519 signature over `haven-push-register-v1:<nodeId>:<token>:<ts>` and a 5-min
/// freshness window. A forger who doesn't hold the identity key can't register under that node id.
/// Also used by /flag with `token` = flagMaterial(...).
async function verifyReg(nodeId, token, ts, sigB64) {
  try {
    if (!ts || !sigB64) return false;
    const now = Math.floor(Date.now() / 1000);
    if (Math.abs(now - Number(ts)) > 300) return false;
    const pub = hexToBytes(nodeId);
    const sig = base64ToBytes(sigB64);
    if (pub.length !== 32 || sig.length !== 64) return false;
    const msg = new TextEncoder().encode(`haven-push-register-v1:${nodeId}:${token}:${ts}`);
    const key = await crypto.subtle.importKey("raw", pub, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify("Ed25519", key, sig, msg);
  } catch {
    return false;
  }
}

function hexToBytes(h) {
  if (typeof h !== "string" || h.length % 2) return new Uint8Array();
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
  return out;
}

function base64ToBytes(b) {
  const bin = atob(b);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/// Soft per-source-IP rate limit (audit F6) so the blind doorbell can't be used to push-spam, ring,
/// or battery-drain a victim. KV is eventually consistent, so this is a best-effort cap, not a hard
/// gate; combine with Cloudflare's own rate-limiting rules for stricter control. ~60 requests/min/IP.
async function rateLimited(env, request, bucket, limit = 60) {
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const key = `rl:${bucket}:${ip}`;
  const n = parseInt((await env.TOKENS.get(key)) || "0", 10) + 1;
  await env.TOKENS.put(key, String(n), { expirationTtl: 60 });
  return n > limit;
}

// ---- APNs failure reporting ----
// Every send site checked `res.ok` and then threw the answer away, so a push that APNs refused was
// indistinguishable from one it delivered — from the worker, from the device, from anywhere. APNs
// puts the actual cause in a JSON `reason` (BadDeviceToken, ExpiredProviderToken, TopicDisallowed,
// InvalidProviderToken …), which is exactly the thing needed to tell "this one token is stale" apart
// from "no push has worked for anyone since the credentials changed". `wrangler tail` surfaces it.
async function logApns(where, res, token) {
  let reason = "";
  try { reason = ((await res.clone().json()) || {}).reason || ""; } catch { /* body not JSON */ }
  console.error(`APNS FAIL ${where} status=${res.status} reason=${reason || "?"} token=${String(token).slice(0, 12)}…`);
}

// ---- APNs provider JWT (ES256), cached ~50 min ----
let _cached = { jwt: null, at: 0 };
async function providerToken(env) {
  const now = Math.floor(Date.now() / 1000);
  if (_cached.jwt && now - _cached.at < 3000) return _cached.jwt;   // reuse for <50 min

  const header = b64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const payload = b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const signingInput = `${header}.${payload}`;

  const key = await crypto.subtle.importKey(
    "pkcs8", pemToBytes(env.APNS_KEY),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]
  );
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput));
  const jwt = `${signingInput}.${b64urlBytes(new Uint8Array(sig))}`;
  _cached = { jwt, at: now };
  return jwt;
}

function pemToBytes(pem) {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}
function b64url(str) { return b64urlBytes(new TextEncoder().encode(str)); }
function b64urlBytes(bytes) {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
