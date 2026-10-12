// desktop/ui-test/uiharness.mjs — fixtures + a stateful fake of the Rust command surface for the DOM tests.
import { loadApp } from './domstub.mjs';

export const HEX = (c) => c.repeat(64);
export const ME = HEX('a');
export const NOW = Date.now();

export const post = (over = {}) => ({
  id: 'p1', author_short: 'aaaaaaaa', author_name: 'You', is_me: true, created_at: NOW - 60_000, body: 'hello world',
  media: [], music: null, edited: false, unsent: false, story: false, mute_video: false, comments: [], reactions: [], ...over,
});

/** A stateful fake of the Rust command surface — just enough behaviour for the UI flows under test. */
export function fakeBackend(over = {}) {
  const s = {
    profile: { name: 'Ada', bio: 'bio', link: '', emoji: '🌿', avatar: '' },
    circles: [{ id: 'default', name: 'My Circle', member_count: 1 }],
    feeds: { default: [post()] },
    dms: {}, threads: [], contacts: [], pending: [], blocked: [],
    ...over.state,
  };
  const be = {
    needs_onboarding: false,
    seedless_status: { seedless: false, linked: false, linking: false },
    demo_mode: false,
    bootstrap: () => ({ node_id_hex: ME, invite_uri: 'haven:invite', invite_link: 'https://haven.is/invite', profile: s.profile, started: true }),
    get_profile: () => s.profile,
    set_profile: (a) => { s.profile = { name: a.name, bio: a.bio, link: a.link, emoji: a.emoji, avatar: a.avatar }; },
    circles: () => s.circles,
    feed: ({ circleId }) => s.feeds[circleId || 'default'] ?? [],
    messages: ({ circleId }) => s.dms[circleId] ?? [],
    dm_threads: () => s.threads,
    contacts: () => s.contacts,
    pending: () => s.pending,
    blocked: () => s.blocked,
    activity: { rows: [], seen_at: 0 },
    activity_seen: 0,
    relay_status: { hosting: false, has_relay: false, relay_active: false, internet_active: true, started: true, relay_link: null, live_media_url: null, live_derp_url: null, path_routed: false },
    relays: [], sync_status: 'synced', kept_stories: [], sensitive_refs: [], pinned_dms: [], scheduled: [],
    privacy_prefs: { notification_detail: 'full', super_data_saver: false, send_original: false },
    video_sound_on: false, take_deep_links: [], reports: [], circle_admins: [], circle_relays: [],
    can_offer_circle_upgrade: false, pending_circle_upgrades: [],
    start_dm: ({ contactIdHex }) => 'dm:' + [ME, contactIdHex].sort().join('-'),
    start_group_dm: ({ members }) => 'dm:' + [ME, ...members.map((m) => m[0])].sort().join('-'),
    instagram_status: null, media_pinned_count: 0,
    relay_public_settings: { public_url: '', tunnel_token: '', auto_tunnel: true, front_door: 'auto', derp_url: '' },
    identities: [{ node_hex: ME, label: 'Identity 1', active: true }],
    device_roster: { enabled: false, this_device_authorized: false, devices: [] },
    enroll_pending: [], erased_relays: [], autostart_status: { login_item: false, host_on_launch: false },
    get_relay_media_limits: { max_age_days: 30, max_bytes: 32 * 1024 ** 3 }, get_media_limits: { days: 0, gb: 0 },
    s3_status: { configured: false, endpoint: '', bucket: '', region: '', access_key: '', prefix: '' },
    media_inventory: [], media_cleanup: { bytes: 0, files: 0 }, reoptimize_scan: { candidates: [], videos_above_target: 0, video_bytes: 0, batch_limit: 20 },
    reoptimize_targets: [], relay_history_status: { phase: 'idle' }, self_test: { all_ok: true, summary: 'ok' },
    low_data_state: { level: 'normal', active: false, description: 'Full speed.' }, erased: [],
    ...over.be,
  };
  return { be, s };
}

export async function boot(over = {}) {
  const { be, s } = fakeBackend(over);
  const app = await loadApp({ backend: be, local: { 'haven-terms-accepted-version': '99', 'haven-named-nudged': '1', ...(over.local ?? {}) } });
  return { app, be, s };
}


export const J = (v) => JSON.parse(JSON.stringify(v));
export const click = async (app, sel) => { const n = typeof sel === 'string' ? app.q(sel) : sel; if (!n) throw new Error(`no element for ${sel}`); n.click(); await app.settle(); };
export const tab = (app, v) => click(app, `.tab[data-view="${v}"]`);
export const lastCall = (app, cmd) => app.calls.filter((c) => c.cmd === cmd).at(-1);
export const BO = HEX('b');
export const DM = `dm:${ME}-${BO}`;
export const withDm = (extra = {}) => ({
  state: {
    contacts: [{ id_hex: BO, name: 'Bo', verify_hex: 'v', emoji: '🦊', avatar: '', bio: 'hi', link: '' }],
    threads: [{ circle_id: DM, name: 'Bo', last_body: 'hey there', last_at: NOW - 5000, member_count: 2, unread: 2 }],
    dms: { [DM]: [post({ id: 'm1', is_me: false, author_short: BO.slice(0, 8), author_name: 'Bo', body: 'hey there' }), post({ id: 'm2', body: 'hi bo', created_at: NOW - 1000 })] },
  },
  ...extra,
});
export const BO_POST = (over = {}) => post({ id: 'bp1', is_me: false, author_short: BO.slice(0, 8), author_name: 'Bo', body: 'bo says hi', reactions: [{ emoji: '❤️', count: 2, mine: false, authors: [] }, { emoji: '😂', count: 1, mine: true, authors: [] }], comments: [{ id: 'c1', author_short: 'x', author_name: 'Cy', is_me: false, created_at: NOW - 3000, body: 'first!', media: [], edited: false, unsent: false, reactions: [] }], ...over });
export const menuBtn = (app, re) => app.qa('#menu-root button').find((b) => re.test(b.textContent));
