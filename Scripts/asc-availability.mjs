#!/usr/bin/env node
/**
 * asc-availability.mjs — inspect / edit the app's App Store territory availability
 * via the ASC API (v2 appAvailabilities).
 *
 *   Scripts/asc-availability.mjs                       # list: is each territory available?
 *   Scripts/asc-availability.mjs --check CHN           # just report one territory
 *   Scripts/asc-availability.mjs --remove CHN --apply  # mark territory unavailable
 *
 * The v2 API replaces the WHOLE availability set on write, so --apply re-submits every
 * territory with its current flag and only flips the requested one. Without --apply the
 * script prints the plan and exits (dry run).
 *
 * Auth: env ASC_API_KEY_ID / ASC_API_ISSUER_ID (falls back to ~/.rocket/config.json),
 * key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8. (Same as asc-resubmit.mjs.)
 */
import { existsSync, readFileSync } from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';
import { join } from 'node:path';
import { homedir } from 'node:os';

const API = 'https://api.appstoreconnect.apple.com';
const die = (m) => { console.error(`✗ ${m}`); process.exit(1); };
const b64url = (b) => Buffer.from(b).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function parseArgs(argv) {
	const a = { bundleId: 'com.blaineam.kith' };
	for (let i = 2; i < argv.length; i++) {
		switch (argv[i]) {
			case '--bundle-id': a.bundleId = argv[++i]; break;
			case '--check': a.check = argv[++i].toUpperCase(); break;
			case '--remove': a.remove = argv[++i].toUpperCase(); break;
			case '--apply': a.apply = true; break;
			default: die(`unknown arg ${argv[i]}`);
		}
	}
	return a;
}

function creds() {
	let keyId = process.env.ASC_API_KEY_ID, issuer = process.env.ASC_API_ISSUER_ID;
	if (!keyId || !issuer) {
		const cfg = join(homedir(), '.rocket/config.json');
		if (existsSync(cfg)) {
			const j = JSON.parse(readFileSync(cfg, 'utf8'));
			keyId = keyId || j.ascKeyId; issuer = issuer || j.ascIssuerId;
		}
	}
	if (!keyId || !issuer) die('No ASC creds (env ASC_API_KEY_ID/ASC_API_ISSUER_ID or ~/.rocket/config.json)');
	const p8 = join(homedir(), '.appstoreconnect/private_keys', `AuthKey_${keyId}.p8`);
	if (!existsSync(p8)) die(`Missing ${p8}`);
	return { keyId, issuer, p8Pem: readFileSync(p8, 'utf8') };
}

function makeToken({ keyId, issuer, p8Pem }) {
	const now = Math.floor(Date.now() / 1000);
	const input = `${b64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }))}.` +
		`${b64url(JSON.stringify({ iss: issuer, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1' }))}`;
	const sig = sign('sha256', Buffer.from(input), { key: createPrivateKey(p8Pem), dsaEncoding: 'ieee-p1363' });
	return `${input}.${b64url(sig)}`;
}

async function api(token, method, path, body) {
	const res = await fetch(path.startsWith('http') ? path : `${API}${path}`, {
		method,
		headers: { authorization: `Bearer ${token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
		body: body ? JSON.stringify(body) : undefined,
	});
	if (res.status === 204) return null;
	const text = await res.text();
	let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
	if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${json?.errors?.map((e) => `${e.title}: ${e.detail}`).join('; ') || text}`);
	return json;
}

async function main() {
	const args = parseArgs(process.argv);
	const token = makeToken(creds());

	const app = (await api(token, 'GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(args.bundleId)}&limit=1`)).data?.[0];
	if (!app) die(`No app for ${args.bundleId}`);

	const avail = (await api(token, 'GET', `/v1/apps/${app.id}/appAvailabilityV2`)).data;
	console.log(`• availableInNewTerritories: ${avail.attributes.availableInNewTerritories}`);

	// Page through every territory's availability flag.
	const territories = [];
	let next = `/v2/appAvailabilities/${avail.id}/territoryAvailabilities?include=territory&limit=200`;
	while (next) {
		const page = await api(token, 'GET', next);
		for (const t of page.data) {
			territories.push({ code: t.relationships.territory.data.id, available: t.attributes.available });
		}
		next = page.links?.next || null;
	}
	const on = territories.filter((t) => t.available);
	console.log(`• ${territories.length} territories total, ${on.length} available`);

	if (args.check) {
		const t = territories.find((x) => x.code === args.check);
		console.log(t ? `• ${args.check}: ${t.available ? 'AVAILABLE' : 'not available'}` : `• ${args.check}: not in list`);
	}

	if (!args.remove) return;
	const target = territories.find((x) => x.code === args.remove);
	if (!target) die(`${args.remove} not in territory list`);
	if (!target.available) { console.log(`• ${args.remove} is already unavailable — nothing to do`); return; }

	console.log(`• Plan: mark ${args.remove} unavailable, keep the other ${on.length - 1} available territories unchanged`);
	if (!args.apply) { console.log('  (dry run — pass --apply to write)'); return; }

	// v2 write REPLACES the whole set: send every territory with its current flag, flipping one.
	const included = territories.map((t, i) => ({
		type: 'territoryAvailabilities',
		id: `${'${'}${i}}`,     // placeholder ids per the v2 create contract
		attributes: { available: t.code === args.remove ? false : t.available },
		relationships: { territory: { data: { type: 'territories', id: t.code } } },
	}));
	await api(token, 'POST', '/v2/appAvailabilities', {
		data: {
			type: 'appAvailabilities',
			attributes: { availableInNewTerritories: avail.attributes.availableInNewTerritories },
			relationships: {
				app: { data: { type: 'apps', id: app.id } },
				territoryAvailabilities: { data: included.map((x) => ({ type: 'territoryAvailabilities', id: x.id })) },
			},
		},
		included,
	});
	console.log(`✓ ${args.remove} marked unavailable`);
}

main().catch((e) => die(e.message));
