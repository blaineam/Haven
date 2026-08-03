#!/usr/bin/env node
/**
 * asc-new-version.mjs — create a NEW App Store version, set its "What's New", attach a build, and
 * submit it for review, entirely via the ASC API. For shipping a patch (e.g. 1.0.1) on top of a
 * live version. Idempotent: re-finds an existing editable version of the same versionString.
 *
 *   Scripts/asc-new-version.mjs --platform IOS    --version 1.0.1 --build 178 \
 *       --notes-file whatsnew.txt --submit
 *   Scripts/asc-new-version.mjs --platform MAC_OS --version 1.0.1 --build 178 \
 *       --notes-file whatsnew.txt --submit
 *
 * `--build latest` attaches the newest VALID build of `--version` instead of naming a number,
 * and `--wait <minutes>` keeps looking while one processes. That pair is what lets CI submit
 * without knowing the build number: Xcode Cloud picks it (from its own run counter) minutes
 * after the tag is pushed, so nothing on the tagging side can predict it.
 *
 *   Scripts/asc-new-version.mjs --platform IOS --version 1.3.0 --build latest --wait 60 --submit
 *
 * Auth: env ASC_API_KEY_ID / ASC_API_ISSUER_ID (falls back to ~/.rocket/config.json), key from
 * env ASC_API_PRIVATE_KEY (the .p8's contents — for CI) else
 * ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
 */
import { readFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { createPrivateKey, sign } from 'node:crypto';
import { join } from 'node:path';
import { homedir } from 'node:os';

const API = 'https://api.appstoreconnect.apple.com';
const die = (m) => { console.error(`✗ ${m}`); process.exit(1); };
const b64url = (b) => Buffer.from(b).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function parseArgs(argv) {
	const a = { bundleId: 'com.blaineam.kith', platform: 'IOS' };
	for (let i = 2; i < argv.length; i++) {
		switch (argv[i]) {
			case '--bundle-id': a.bundleId = argv[++i]; break;
			case '--platform': a.platform = argv[++i]; break;
			case '--version': a.version = argv[++i]; break;
			case '--build': a.build = argv[++i]; break;
			case '--wait': a.waitMinutes = Number(argv[++i]); break;
			case '--notes-file': a.notesFile = argv[++i]; break;
			case '--submit': a.submit = true; break;
			default: die(`unknown arg ${argv[i]}`);
		}
	}
	if (!a.version) die('--version required');
	if (a.waitMinutes !== undefined && !Number.isFinite(a.waitMinutes)) die('--wait wants minutes');
	return a;
}

function creds() {
	let keyId = process.env.ASC_API_KEY_ID, issuer = process.env.ASC_API_ISSUER_ID;
	if (!keyId || !issuer) {
		const cfg = join(homedir(), '.rocket/config.json');
		if (existsSync(cfg)) { const j = JSON.parse(readFileSync(cfg, 'utf8')); keyId = keyId || j.ascKeyId; issuer = issuer || j.ascIssuerId; }
	}
	if (!keyId || !issuer) die('No ASC creds');
	// CI has no home directory to drop a .p8 into, and writing one to the runner's disk just to
	// read it back is a secret on disk for no reason — take the key material straight from the env.
	const inline = process.env.ASC_API_PRIVATE_KEY;
	if (inline && inline.includes('BEGIN')) return { keyId, issuer, p8Pem: inline };
	const p8 = join(homedir(), '.appstoreconnect/private_keys', `AuthKey_${keyId}.p8`);
	if (!existsSync(p8)) die(`Missing ${p8} (and no ASC_API_PRIVATE_KEY in the environment)`);
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
		method, headers: { authorization: `Bearer ${token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
		body: body ? JSON.stringify(body) : undefined,
	});
	if (res.status === 204) return null;
	const text = await res.text();
	let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* */ }
	if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${json?.errors?.map((e) => `${e.title}: ${e.detail}`).join('; ') || text}`);
	return json;
}

const EDITABLE = new Set(['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY']);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * The build to attach.
 *
 * `--build <n>` names one. `--build latest` takes the newest VALID build of THIS marketing version
 * — note `filter[version]` on /v1/builds is the build NUMBER, so the marketing version is matched
 * through `preReleaseVersion.version`; filtering on the wrong one silently finds nothing.
 *
 * With `--wait`, keep looking. A freshly uploaded build sits in PROCESSING for a few minutes, and a
 * CI job that runs the moment a tag is pushed will nearly always get there first — "not VALID yet"
 * is the expected first answer, not an error.
 */
async function resolveBuild(token, appId, args) {
	const wantLatest = String(args.build).toLowerCase() === 'latest';
	const query = wantLatest
		? `/v1/builds?filter[app]=${appId}&filter[preReleaseVersion.version]=${encodeURIComponent(args.version)}` +
		  `&filter[preReleaseVersion.platform]=${args.platform}&sort=-uploadedDate&limit=10`
		: `/v1/builds?filter[app]=${appId}&filter[version]=${encodeURIComponent(args.build)}` +
		  `&filter[preReleaseVersion.platform]=${args.platform}&sort=-uploadedDate&limit=5`;
	const deadline = Date.now() + (args.waitMinutes ?? 0) * 60_000;
	let seen = 'none';
	for (;;) {
		const builds = (await api(token, 'GET', query)).data || [];
		const valid = builds.find((b) => b.attributes.processingState === 'VALID');
		if (valid) return valid;
		seen = builds.map((b) => `${b.attributes.version}:${b.attributes.processingState}`).join(', ') || 'none';
		if (Date.now() >= deadline) break;
		console.log(`• Waiting for a VALID ${args.platform} build of ${args.version} (saw: ${seen})…`);
		await sleep(60_000);
	}
	die(wantLatest
		? `No VALID ${args.platform} build of ${args.version} — states: ${seen}`
		: `Build ${args.build} (${args.platform}) not VALID yet — states: ${seen}`);
}

async function main() {
	const args = parseArgs(process.argv);
	const token = makeToken(creds());
	const app = (await api(token, 'GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(args.bundleId)}&limit=1`)).data?.[0];
	if (!app) die(`No app for ${args.bundleId}`);

	// Find an existing version with this string, else create it.
	const versions = (await api(token, 'GET', `/v1/apps/${app.id}/appStoreVersions?filter[platform]=${args.platform}&limit=30`)).data || [];
	let version = versions.find((v) => v.attributes.versionString === args.version);
	if (version && !EDITABLE.has(version.attributes.appStoreState)) {
		die(`${args.platform} ${args.version} exists but is ${version.attributes.appStoreState} (not editable)`);
	}
	if (!version) {
		version = (await api(token, 'POST', '/v1/appStoreVersions', {
			data: {
				type: 'appStoreVersions',
				attributes: { platform: args.platform, versionString: args.version },
				relationships: { app: { data: { type: 'apps', id: app.id } } },
			},
		})).data;
		console.log(`• Created ${args.platform} version ${args.version}`);
	} else {
		console.log(`• Reusing editable ${args.platform} version ${args.version} (${version.attributes.appStoreState})`);
	}

	// "What's New" — set on every localization for the version.
	if (args.notesFile) {
		const notes = (await readFile(args.notesFile, 'utf8')).trim();
		const locs = (await api(token, 'GET', `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=50`)).data || [];
		for (const loc of locs) {
			await api(token, 'PATCH', `/v1/appStoreVersionLocalizations/${loc.id}`, {
				data: { type: 'appStoreVersionLocalizations', id: loc.id, attributes: { whatsNew: notes } },
			});
		}
		console.log(`• Set "What's New" on ${locs.length} localization(s)`);
	}

	// Attach the build (must be VALID).
	if (args.build) {
		const build = await resolveBuild(token, app.id, args);
		await api(token, 'PATCH', `/v1/appStoreVersions/${version.id}/relationships/build`, { data: { type: 'builds', id: build.id } });
		console.log(`• Attached build ${build.attributes.version} (${build.id})`);
	}

	if (!args.submit) { console.log('• (not submitting — pass --submit)'); return; }

	// Create a review submission and add this version as an item.
	let sub = ((await api(token, 'GET', `/v1/reviewSubmissions?filter[app]=${app.id}&filter[platform]=${args.platform}&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES&limit=5`)).data || [])[0];
	if (sub && ['WAITING_FOR_REVIEW', 'IN_REVIEW'].includes(sub.attributes.state)) { console.log(`• Submission already ${sub.attributes.state}`); return; }
	if (!sub) {
		sub = (await api(token, 'POST', '/v1/reviewSubmissions', {
			data: { type: 'reviewSubmissions', attributes: { platform: args.platform }, relationships: { app: { data: { type: 'apps', id: app.id } } } },
		})).data;
		console.log(`• Created review submission ${sub.id}`);
	}
	// Add the version item (idempotent-ish: ignore if already present).
	try {
		await api(token, 'POST', '/v1/reviewSubmissionItems', {
			data: { type: 'reviewSubmissionItems', relationships: { reviewSubmission: { data: { type: 'reviewSubmissions', id: sub.id } }, appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } } },
		});
		console.log('• Added version to the submission');
	} catch (e) { console.log(`• (item add: ${e.message.split(':').slice(-1)[0].trim()})`); }
	await api(token, 'PATCH', `/v1/reviewSubmissions/${sub.id}`, { data: { type: 'reviewSubmissions', id: sub.id, attributes: { submitted: true } } });
	console.log(`✓ Submitted ${args.platform} ${args.version} for review`);
}
main().catch((e) => die(e.message));
