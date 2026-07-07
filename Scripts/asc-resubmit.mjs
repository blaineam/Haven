#!/usr/bin/env node
/**
 * asc-resubmit.mjs — prep + resubmit an App Store version for review, entirely
 * via the ASC API: review notes, a review ATTACHMENT (e.g. the App Review 1.2
 * demo video — no iCloud/Dropbox hosting needed, reviewers see it inline),
 * the build to review, and the review submission itself.
 *
 * Steps are independent + idempotent, so you can attach the video while the
 * build is still processing and submit later:
 *
 *   # notes + video now:
 *   Scripts/asc-resubmit.mjs --platform MAC_OS --notes-file notes.txt --attach demo.mp4
 *   # once the build shows up / finishes processing:
 *   Scripts/asc-resubmit.mjs --platform MAC_OS --build 176 --submit
 *
 * Auth: env ASC_API_KEY_ID / ASC_API_ISSUER_ID (falls back to ~/.rocket/config.json),
 * key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
 */
import { readFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { createPrivateKey, sign, createHash } from 'node:crypto';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';

const API = 'https://api.appstoreconnect.apple.com';
const die = (m) => { console.error(`✗ ${m}`); process.exit(1); };
const b64url = (b) => Buffer.from(b).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function parseArgs(argv) {
	const a = { bundleId: 'com.blaineam.kith', platform: 'MAC_OS' };
	for (let i = 2; i < argv.length; i++) {
		switch (argv[i]) {
			case '--bundle-id': a.bundleId = argv[++i]; break;
			case '--platform': a.platform = argv[++i]; break;
			case '--notes-file': a.notesFile = argv[++i]; break;
			case '--attach': a.attach = argv[++i]; break;
			case '--build': a.build = argv[++i]; break;
			case '--submit': a.submit = true; break;
			case '--status': a.status = true; break;
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

const EDITABLE = new Set(['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY']);

async function main() {
	const args = parseArgs(process.argv);
	const token = makeToken(creds());

	const app = (await api(token, 'GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(args.bundleId)}&limit=1`)).data?.[0];
	if (!app) die(`No app for ${args.bundleId}`);

	const versions = (await api(token, 'GET', `/v1/apps/${app.id}/appStoreVersions?filter[platform]=${args.platform}&limit=20`)).data || [];
	const version = versions.find((v) => EDITABLE.has(v.attributes.appStoreState));
	if (args.status) {
		for (const v of versions.slice(0, 5)) console.log(`  ${v.attributes.versionString} (${args.platform}): ${v.attributes.appStoreState}`);
		if (!version) return;
	}
	if (!version) die(`No editable ${args.platform} version (states: ${versions.map((v) => v.attributes.appStoreState).join(', ')})`);
	console.log(`• Editable ${args.platform} version ${version.attributes.versionString} (${version.attributes.appStoreState})`);

	// ---- Review detail (notes + attachments live under it) ---------------------------------
	let detail = (await api(token, 'GET', `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`).catch(() => null))?.data;
	if (!detail && (args.notesFile || args.attach)) {
		detail = (await api(token, 'POST', '/v1/appStoreReviewDetails', {
			data: {
				type: 'appStoreReviewDetails',
				relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } },
			},
		})).data;
		console.log('• Created appStoreReviewDetail');
	}

	if (args.notesFile) {
		const notes = (await readFile(args.notesFile, 'utf8')).trim();
		await api(token, 'PATCH', `/v1/appStoreReviewDetails/${detail.id}`, {
			data: { type: 'appStoreReviewDetails', id: detail.id, attributes: { notes } },
		});
		console.log(`• Review notes set (${notes.length} chars)`);
	}

	if (args.attach) {
		const buf = await readFile(args.attach);
		const fileName = basename(args.attach);
		// Replace any existing attachment with the same name (idempotent re-runs).
		const existing = (await api(token, 'GET', `/v1/appStoreReviewDetails/${detail.id}/appStoreReviewAttachments?limit=10`)).data || [];
		for (const at of existing.filter((x) => x.attributes.fileName === fileName)) {
			await api(token, 'DELETE', `/v1/appStoreReviewAttachments/${at.id}`);
			console.log(`  deleted stale attachment ${at.id}`);
		}
		const reservation = (await api(token, 'POST', '/v1/appStoreReviewAttachments', {
			data: {
				type: 'appStoreReviewAttachments',
				attributes: { fileName, fileSize: buf.length },
				relationships: { appStoreReviewDetail: { data: { type: 'appStoreReviewDetails', id: detail.id } } },
			},
		})).data;
		for (const op of reservation.attributes.uploadOperations) {
			const headers = {};
			for (const h of op.requestHeaders) headers[h.name] = h.value;
			const res = await fetch(op.url, { method: op.method, headers, body: buf.subarray(op.offset, op.offset + op.length) });
			if (!res.ok) throw new Error(`attachment PUT → ${res.status}`);
		}
		await api(token, 'PATCH', `/v1/appStoreReviewAttachments/${reservation.id}`, {
			data: {
				type: 'appStoreReviewAttachments',
				id: reservation.id,
				attributes: { uploaded: true, sourceFileChecksum: createHash('md5').update(buf).digest('hex') },
			},
		});
		console.log(`• Attached ${fileName} (${(buf.length / 1e6).toFixed(1)} MB) for App Review`);
	}

	// ---- Build selection --------------------------------------------------------------------
	if (args.build) {
		const builds = (await api(token, 'GET',
			`/v1/builds?filter[app]=${app.id}&filter[version]=${args.build}&sort=-uploadedDate&limit=5`)).data || [];
		const build = builds.find((b) => b.attributes.processingState === 'VALID');
		if (!build) {
			const states = builds.map((b) => `${b.attributes.version}:${b.attributes.processingState}`).join(', ') || 'none found';
			die(`Build ${args.build} not VALID yet (${states}) — re-run once processing completes`);
		}
		await api(token, 'PATCH', `/v1/appStoreVersions/${version.id}/relationships/build`, {
			data: { type: 'builds', id: build.id },
		});
		console.log(`• Version ${version.attributes.versionString} now uses build ${args.build}`);
	}

	// ---- Submit -------------------------------------------------------------------------------
	if (args.submit) {
		// Reuse an open submission if one exists, else create one.
		let sub = ((await api(token, 'GET',
			`/v1/reviewSubmissions?filter[app]=${app.id}&filter[platform]=${args.platform}&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES&limit=5`)).data || [])[0];
		if (!sub || ['WAITING_FOR_REVIEW', 'IN_REVIEW'].includes(sub.attributes.state)) {
			if (sub) { console.log(`• Submission already ${sub.attributes.state}`); return; }
			sub = (await api(token, 'POST', '/v1/reviewSubmissions', {
				data: {
					type: 'reviewSubmissions',
					attributes: { platform: args.platform },
					relationships: { app: { data: { type: 'apps', id: app.id } } },
				},
			})).data;
			console.log(`• Created review submission ${sub.id}`);
		} else {
			console.log(`• Reusing open submission ${sub.id} (${sub.attributes.state})`);
		}
		const items = (await api(token, 'GET', `/v1/reviewSubmissions/${sub.id}/items?limit=10`)).data || [];
		if (!items.length) {
			await api(token, 'POST', '/v1/reviewSubmissionItems', {
				data: {
					type: 'reviewSubmissionItems',
					relationships: {
						reviewSubmission: { data: { type: 'reviewSubmissions', id: sub.id } },
						appStoreVersionForReview: { data: { type: 'appStoreVersions', id: version.id } },
					},
				},
			});
			console.log('• Added version to the submission');
		}
		await api(token, 'PATCH', `/v1/reviewSubmissions/${sub.id}`, {
			data: { type: 'reviewSubmissions', id: sub.id, attributes: { submitted: true } },
		});
		console.log('✓ Submitted for review');
	}
}

main().catch((e) => die(e.stack || String(e)));
