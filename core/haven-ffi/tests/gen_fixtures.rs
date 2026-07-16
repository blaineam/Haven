//! Golden-fixture GENERATOR for the Tier-1 migration harness.
//!
//! These are `#[ignore]`d on purpose: they WRITE the committed `tests/fixtures/*.b64` files rather than
//! assert anything, so a normal `cargo test` never touches them. Regenerate deliberately with:
//!
//!     cargo test -p haven_ffi --test gen_fixtures -- --ignored --nocapture
//!
//! The fixtures are frozen snapshots of the CURRENT on-disk persisted-state format. `migration_harness.rs`
//! loads them with today's engine and asserts full fidelity — so if a future serialization change drops or
//! reshapes a field, loading an OLD fixture loses data and the harness fails loudly. That is the tripwire.
//!
//! Determinism: every input here is a fixed seed / fixed timestamp, so a regenerated fixture differs from
//! the committed one only in the ordering of the engine's HashMap-backed arrays (device rosters, per-circle
//! epoch keys) — which `import_state` reads order-independently. See the round-trip note in the harness.

mod common;
use common::*;

/// Build the canonical "rich primary account" and return its exported state bytes. Shared by the golden
/// generator and the schema down-converters below so all three fixtures describe the SAME account.
///
/// Shape (all deterministic from fixed seeds `1/2/3` + device seed `91`, fixed timestamps):
///   • default circle  — members {me, Bob}; my post "p-default-1" carrying a media ref; Bob's post
///                        "b-default-1" (synced in); my comment on my own post.
///   • "fam" circle     — members {me, Carol}; my post "p-fam-1".
///   • my two-device roster {account, device} installed (rides `device_rosters`).
fn build_rich_account_state() -> Vec<u8> {
    let me = account(1);
    let bob = account(2);
    let carol = account(3);
    assert!(me.use_device_identity(vec![91u8; 32]));

    // default circle
    me.add_contact_bundle(DEFAULT_CIRCLE.into(), bob.my_bundle()).unwrap();
    bob.add_contact_bundle(DEFAULT_CIRCLE.into(), me.my_bundle()).unwrap();
    me.post(DEFAULT_CIRCLE.into(), "p-default-1".into(), vec!["media/ref-abc".into()], None, None, false, false, 1_000)
        .unwrap();
    // Bob authors and we ingest it, so the fixture carries content authored by SOMEONE ELSE too.
    bob.post(DEFAULT_CIRCLE.into(), "b-default-1".into(), vec![], None, None, false, false, 1_100).unwrap();
    for env in bob.sync_envelopes(DEFAULT_CIRCLE.into()) {
        let _ = me.receive(DEFAULT_CIRCLE.into(), env);
    }
    // Comment on my own post (exercises the comment event path). Target id comes from my own feed.
    let my_post_id = me
        .feed(DEFAULT_CIRCLE.into(), 2_000, None)
        .into_iter()
        .find(|f| f.body == "p-default-1")
        .expect("my post is in my feed")
        .id;
    me.comment(DEFAULT_CIRCLE.into(), my_post_id, "c-default-1".into(), vec![], 1_200).unwrap();

    // my two-device roster (account + device 91)
    install_two_device_roster(&me, [1u8; 32]);

    // "fam" circle
    me.create_circle("fam".into(), "Family".into());
    me.add_contact_bundle("fam".into(), carol.my_bundle()).unwrap();
    me.post("fam".into(), "p-fam-1".into(), vec![], None, None, false, false, 2_000).unwrap();

    me.export_state()
}

/// GOLDEN: the full current-format persisted state of the rich account. Loaded by
/// `golden_multicircle_restores_with_full_fidelity`.
#[test]
#[ignore = "generator: writes tests/fixtures/account_multicircle.b64"]
fn gen_account_multicircle() {
    let bytes = build_rich_account_state();
    // sanity: it must parse as the current PersistState (a JSON object with a "circles" array).
    let v: serde_json::Value = serde_json::from_slice(&bytes).expect("export is valid JSON");
    assert!(v.get("circles").and_then(|c| c.as_array()).is_some(), "current format has a circles array");
    write_fixture("account_multicircle.b64", &bytes);
    eprintln!("wrote account_multicircle.b64 ({} bytes of state)", bytes.len());
}

/// GOLDEN (oldest schema): the `LegacyPersistState` single-circle form `{events, contacts}` that predates
/// multi-circle support. Built by lifting the default circle's real (signed) events + member bundles out of
/// a current export and re-wrapping them in the legacy envelope. Loaded by
/// `golden_legacy_v0_migrates_into_default_circle`.
#[test]
#[ignore = "generator: writes tests/fixtures/legacy_v0.b64"]
fn gen_legacy_v0() {
    let bytes = build_rich_account_state();
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let default_circle = v["circles"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "default")
        .expect("default circle present");
    let legacy = serde_json::json!({
        "events": default_circle["events"].clone(),
        "contacts": default_circle["members"].clone(),
    });
    let out = serde_json::to_vec(&legacy).unwrap();
    write_fixture("legacy_v0.b64", &out);
    eprintln!("wrote legacy_v0.b64 ({} bytes)", out.len());
}

/// GOLDEN (older PersistState schema): the multi-circle format BEFORE epoch keys / device rosters / seedless
/// wire existed — every field that is `#[serde(default)]` today is simply absent. Built by stripping those
/// fields from a current export. Loading it proves forward-migration: the missing fields default safely and
/// NOTHING is wiped (the absence-as-deletion guard). Loaded by
/// `golden_pre_epoch_schema_defaults_missing_fields_safely`.
#[test]
#[ignore = "generator: writes tests/fixtures/pre_epoch.b64"]
fn gen_pre_epoch() {
    let bytes = build_rich_account_state();
    let mut v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    // Drop the top-level fields added after the original multi-circle format.
    let obj = v.as_object_mut().unwrap();
    obj.remove("device_rosters");
    obj.remove("seedless_roster_wire");
    obj.remove("cached_profile");
    // Drop the per-circle fields added when epoch ratchets landed — keep ONLY {id, name, members, events}.
    for c in v["circles"].as_array_mut().unwrap() {
        let c = c.as_object_mut().unwrap();
        for k in [
            "my_epoch",
            "my_epoch_keys",
            "peer_epoch_keys",
            "my_circle_secret",
            "peer_circle_secrets",
            "rotated_at",
            "cached_commit",
            "pending_epoch",
        ] {
            c.remove(k);
        }
    }
    let out = serde_json::to_vec(&v).unwrap();
    write_fixture("pre_epoch.b64", &out);
    eprintln!("wrote pre_epoch.b64 ({} bytes)", out.len());
}
