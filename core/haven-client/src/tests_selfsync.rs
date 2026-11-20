//! Multi-device self-sync: what a device publishes (`current_local`) and how a sibling folds it in
//! (`apply_local`) — last-writer-wins stamps, tombstones that must beat re-syncs, additive circle
//! state, and the device id file.

use super::*;
use crate::covtest_util::tmp_paths;

const R1: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn social(b: u8) -> std::sync::Arc<HavenSocial> {
    HavenSocial::new(vec![b; 32]).unwrap()
}

fn entries(m: &BTreeMap<String, Vec<u8>>) -> Vec<(String, Vec<u8>)> {
    m.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
}

fn u64le(n: u64) -> Vec<u8> {
    n.to_le_bytes().to_vec()
}

fn contact(hex: &str, name: &str) -> Contact {
    Contact {
        id_hex: hex.into(),
        name: name.into(),
        verify_hex: "v".into(),
        emoji: String::new(),
        avatar: String::new(),
        bio: String::new(),
        link: String::new(),
    }
}

#[test]
fn the_device_id_is_minted_once_and_survives_a_reload() {
    let paths = tmp_paths();
    let a = device_id(&paths);
    assert_eq!(device_id(&paths), a, "same file, same id");
    assert_ne!(device_id(&tmp_paths()), a, "different data dir, different id");
    std::fs::write(paths.selfsync_device_file(), b"short").unwrap();
    let c = device_id(&paths);
    assert_ne!(c, [0u8; 32]);
    assert_eq!(std::fs::read(paths.selfsync_device_file()).unwrap().len(), 32, "a malformed id file is replaced");
}

#[test]
fn an_empty_device_publishes_only_its_defaults() {
    let m = current_local(&Prefs::default(), &social(1));
    assert!(m.contains_key("setting:retention") && m.contains_key("setting:retentionDays") && m.contains_key("setting:host_on_launch"));
    assert!(!m.keys().any(|k| k.starts_with("profile:")), "empty profile fields are not published");
    assert!(m.keys().any(|k| k.starts_with("circle:default")), "the personal circle is always present");
}

#[test]
fn published_state_carries_profile_settings_and_tombstones() {
    let mut p = Prefs::default();
    p.profile.name = "Ada".into();
    p.profile.avatar = "data:image/jpeg;base64,AA".into();
    p.stamp_profile_field("name");
    p.retention_secs = Some(3 * 86_400);
    p.stamp_setting("retention");
    p.host_on_launch = true;
    p.pinned_dms = vec!["dm:a-b".into(), "dm:c-d".into()];
    p.activity_seen_at = 77;
    p.dm_last_read.insert("dm:a-b".into(), 9);
    p.contacts.push(contact("c1", "Cee"));
    p.blocked.push("bad".into());
    p.contact_removed_at.insert("gone".into(), 5);
    p.circle_deleted_at.insert("old".into(), 6);
    p.circle_removed_at.insert("cid|member".into(), 7);
    p.forgot_at_relays.insert(R1.into(), 8);
    let m = current_local(&p, &social(2));
    assert_eq!(m["profile:name"], b"Ada");
    assert!(m.contains_key("profile-at:name") && !m.contains_key("profile-at:bio"));
    assert_eq!(m["setting:retentionDays"], 3i32.to_le_bytes());
    assert_eq!(m["setting:retention"], u64le(3 * 86_400));
    assert_eq!(m["setting:host_on_launch"], vec![1]);
    assert_eq!(m["setting:pinnedDMs"], b"dm:a-b\ndm:c-d");
    assert_eq!(m["setting:activitySeenAt"], u64le(77));
    assert!(m.contains_key("setting:dmLastRead") && m.contains_key("contact:c1"));
    assert_eq!(m["blocked:bad"], vec![1]);
    assert_eq!(m["contact-removed:gone"], u64le(5));
    assert_eq!(m["circle-deleted:old"], u64le(6));
    assert_eq!(m["circle-removed:cid|member"], u64le(7));
    assert_eq!(m["removal:cid|member"], vec![1], "legacy boolean mirror for older clients");
    assert_eq!(m[&format!("relay-removal:{R1}")], u64le(8));
    assert_eq!(m["setting-at:haven.retentionDays"].len(), 8);
}

#[test]
fn deleted_circles_are_not_published() {
    let s = social(3);
    let id = s.create_circle_owned("Temp".into());
    let mut p = Prefs::default();
    assert!(current_local(&p, &s).contains_key(&format!("circle:{id}")));
    p.mark_circle_deleted(&id);
    assert!(!current_local(&p, &s).contains_key(&format!("circle:{id}")));
}

#[test]
fn a_sibling_adopts_profile_fields_only_when_newer() {
    let mut src = Prefs::default();
    src.profile.name = "Remote".into();
    src.profile.bio = "remote bio".into();
    src.profile_field_ts.insert("name".into(), 100);
    src.profile_field_ts.insert("bio".into(), 100);
    let e = entries(&current_local(&src, &social(4)));

    let mut dst = Prefs::default();
    dst.profile.name = "Local".into();
    dst.profile_field_ts.insert("name".into(), 500); // newer locally
    let s = social(5);
    assert!(apply_local(&e, &mut dst, &s));
    assert_eq!(dst.profile.name, "Local", "a newer local edit wins");
    assert_eq!(dst.profile.bio, "remote bio", "an empty local field takes the newer remote one");
    assert_eq!(dst.profile_field_stamp("bio"), 100);
    // Idempotent.
    assert!(!apply_local(&e, &mut dst, &s));
}

#[test]
fn legacy_untimestamped_siblings_seed_only_empty_fields() {
    let mut dst = Prefs::default();
    dst.profile.link = "https://mine".into();
    let e = vec![
        ("profile:name".to_string(), b"Legacy".to_vec()),
        ("profile:link".to_string(), b"https://theirs".to_vec()),
        ("profile:emoji".to_string(), Vec::new()),
        ("profile:avatar".to_string(), b"AVATAR".to_vec()),
    ];
    assert!(apply_local(&e, &mut dst, &social(6)));
    assert_eq!(dst.profile.name, "Legacy", "empty local name is seeded");
    assert_eq!(dst.profile.link, "https://mine", "an existing untimestamped value is not clobbered");
    assert_eq!(dst.profile.avatar, "AVATAR");
    assert!(dst.profile.emoji.is_empty(), "an empty emoji never wipes");
}

#[test]
fn settings_sync_by_timestamp_and_pins_are_capped() {
    let mut dst = Prefs::default();
    dst.retention_secs = Some(86_400);
    dst.setting_ts.insert("retention".into(), 50);
    let newer = vec![
        ("setting:retentionDays".to_string(), 7i32.to_le_bytes().to_vec()),
        ("setting-at:retention".to_string(), u64le(60)),
        ("setting:host_on_launch".to_string(), vec![1]),
        ("setting:pinnedDMs".to_string(), (0..9).map(|i| format!("dm{i}")).collect::<Vec<_>>().join("\n").into_bytes()),
        ("setting:activitySeenAt".to_string(), u64le(1234)),
        ("setting:dmLastRead".to_string(), br#"{"dm1":10,"dm2":20}"#.to_vec()),
    ];
    assert!(apply_local(&newer, &mut dst, &social(7)));
    assert_eq!(dst.retention_secs, Some(7 * 86_400));
    assert!(dst.host_on_launch);
    assert_eq!(dst.pinned_dms.len(), 6);
    assert_eq!(dst.activity_seen_at, 1234);
    assert_eq!(dst.dm_last_read["dm2"], 20);

    // Older stamp and lower watermarks do not move anything backwards.
    let stale = vec![
        ("setting:retentionDays".to_string(), 1i32.to_le_bytes().to_vec()),
        ("setting-at:retention".to_string(), u64le(10)),
        ("setting:activitySeenAt".to_string(), u64le(5)),
        ("setting:dmLastRead".to_string(), br#"{"dm1":1}"#.to_vec()),
    ];
    assert!(!apply_local(&stale, &mut dst, &social(7)));
    assert_eq!(dst.retention_secs, Some(7 * 86_400));
    assert_eq!(dst.activity_seen_at, 1234);
    assert_eq!(dst.dm_last_read["dm1"], 10);

    // Zero days clears the auto-delete window.
    let clear = vec![("setting:retentionDays".to_string(), 0i32.to_le_bytes().to_vec()), ("setting-at:retention".to_string(), u64le(999))];
    assert!(apply_local(&clear, &mut dst, &social(7)));
    assert_eq!(dst.retention_secs, None);

    // The legacy seconds key applies when the days key is absent.
    let legacy = vec![("setting:retention".to_string(), u64le(5 * 86_400)), ("setting-at:retention".to_string(), u64le(2000))];
    assert!(apply_local(&legacy, &mut dst, &social(7)));
    assert_eq!(dst.retention_secs, Some(5 * 86_400));
    // Malformed widths are ignored rather than panicking.
    let junk = vec![("setting:retentionDays".to_string(), vec![1]), ("setting:host_on_launch".to_string(), vec![])];
    assert!(!apply_local(&junk, &mut dst, &social(7)));
}

#[test]
fn contacts_and_blocks_converge_and_tombstones_beat_stale_records() {
    let mut dst = Prefs::default();
    dst.contacts.push(contact("old", "Old Friend"));
    dst.contacts.push(contact("kept", "Kept"));
    dst.blocked.push("unblocked-elsewhere".into());
    let mut src = Prefs::default();
    src.contacts.push(contact("kept", "Kept Renamed"));
    src.contacts.push(contact("new", "New Friend"));
    src.blocked.push("blocked-elsewhere".into());
    src.contact_removed_at.insert("old".into(), 100);
    let mut e = entries(&current_local(&src, &social(8)));
    assert!(apply_local(&e, &mut dst, &social(9)));
    let names: Vec<_> = dst.contacts.iter().map(|c| (c.id_hex.as_str(), c.name.as_str())).collect();
    assert!(names.contains(&("kept", "Kept Renamed")) && names.contains(&("new", "New Friend")), "{names:?}");
    assert!(!names.iter().any(|(id, _)| *id == "old"), "a newer removal drops the contact");
    assert_eq!(dst.blocked, vec!["blocked-elsewhere".to_string()], "blocked set mirrors the published one");

    // A stale additive contact record cannot resurrect a removed person.
    e.push(("contact:old".to_string(), serde_json::to_vec(&contact("old", "Old Friend")).unwrap()));
    apply_local(&e, &mut dst, &social(9));
    assert!(!dst.contacts.iter().any(|c| c.id_hex == "old"));

    // A newer re-add wins over the removal.
    let readd = vec![
        ("contact-removed:old".to_string(), u64le(100)),
        ("contact-readd:old".to_string(), u64le(200)),
        ("contact:old".to_string(), serde_json::to_vec(&contact("old", "Old Friend")).unwrap()),
    ];
    let mut dst2 = Prefs::default();
    dst2.contact_removed_at.insert("old".into(), 100);
    assert!(apply_local(&readd, &mut dst2, &social(9)));
    assert!(dst2.contacts.iter().any(|c| c.id_hex == "old"));
}

#[test]
fn relay_forget_and_readd_resolve_by_timestamp() {
    let mut dst = Prefs::default();
    dst.ensure_relay_entry(R1, None, false, true);
    dst.relay_entries.get_mut(R1).unwrap().added_at_ms = 10;
    let del = vec![(format!("relay-removal:{R1}"), u64le(500))];
    assert!(apply_local(&del, &mut dst, &social(10)));
    assert!(!dst.relay_is_active(R1));
    let readd = vec![(format!("relay-removal:{R1}"), u64le(500)), (format!("relay-readd:{R1}"), u64le(900))];
    assert!(apply_local(&readd, &mut dst, &social(10)));
    assert!(dst.suppressed_relays.is_empty());
}

#[test]
fn circle_deletion_and_member_removal_apply_to_the_engine() {
    let s = social(11);
    let id = s.create_circle_owned("Doomed".into());
    let mut dst = Prefs::default();
    let del = vec![(format!("circle-deleted:{id}"), u64le(300))];
    assert!(apply_local(&del, &mut dst, &s));
    assert!(dst.is_circle_deleted(&id));
    assert!(!s.circles().iter().any(|c| c.id == id), "the engine drops the deleted circle");
    // Recreated later wins.
    let rec = vec![(format!("circle-deleted:{id}"), u64le(300)), (format!("circle-recreated:{id}"), u64le(400))];
    apply_local(&rec, &mut dst, &s);
    assert!(!dst.is_circle_deleted(&id));

    // Member severance is recorded, and a re-add newer than it lifts it.
    let entry = "cid|abcd".to_string();
    let sever = vec![(format!("circle-removed:{entry}"), u64le(50))];
    assert!(apply_local(&sever, &mut dst, &s));
    assert!(dst.is_circle_member_removed(&entry));
    let back = vec![(format!("circle-removed:{entry}"), u64le(50)), (format!("circle-readd:{entry}"), u64le(60))];
    assert!(apply_local(&back, &mut dst, &s));
    assert!(!dst.is_circle_member_removed(&entry));
    // Entries without a circle|member shape are ignored.
    let weird = vec![("circle-removed:nopipe".to_string(), u64le(5))];
    assert!(!apply_local(&weird, &mut dst, &s));
}

#[test]
fn circles_sync_additively_creating_renaming_and_wiring_relays() {
    let a = social(12);
    let b = social(13);
    let id = a.create_circle_owned("Hikers".into());
    a.add_contact_bundle(id.clone(), b.my_bundle()).unwrap();
    let mut pa = Prefs::default();
    pa.relays.insert(id.clone(), vec![R1.into()]);
    pa.created_circles.push(id.clone());
    let e = entries(&current_local(&pa, &a));

    // The other device (same account seed) learns the circle, its member and its relay.
    let a2 = social(12);
    let mut pb = Prefs::default();
    assert!(apply_local(&e, &mut pb, &a2));
    let c = a2.circles().into_iter().find(|c| c.id == id).expect("circle created on the sibling");
    assert_eq!(c.name, "Hikers");
    assert!(a2.contact_node_ids(id.clone()).contains(&b.my_node_hex()), "members ride along");
    assert_eq!(pb.relays[&id], vec![R1.to_string()]);

    // Renamed upstream → renamed here; a suppressed relay is not wired back in.
    a.rename_circle(id.clone(), "Climbers".into());
    let e2 = entries(&current_local(&pa, &a));
    pb.suppressed_relays.push("zz".into());
    assert!(apply_local(&e2, &mut pb, &a2));
    assert_eq!(a2.circles().into_iter().find(|c| c.id == id).unwrap().name, "Climbers");

    // A severed member is never re-added from a stale circle record.
    let b_hex = b.my_node_hex().to_lowercase();
    let a3 = social(12);
    let mut pc = Prefs::default();
    pc.mark_circle_member_removed(&format!("{id}|{b_hex}"));
    apply_local(&e, &mut pc, &a3);
    assert!(!a3.contact_node_ids(id).contains(&b.my_node_hex()), "severance wins over the additive record");
}

#[test]
fn kept_stories_merge_through_the_sync_key() {
    let mut src = Prefs::default();
    src.kept_stories.push(crate::store::KeptStory {
        id: "k1".into(),
        body: "b".into(),
        media: vec!["img_1".into()],
        created_at: 1,
        kept_at: Some(2),
        music_catalog_id: None,
        music_title: None,
        music_artist: None,
        music_artwork_url: None,
        music_duration_ms: None,
    });
    let e = entries(&current_local(&src, &social(14)));
    assert!(e.iter().any(|(k, _)| k == "setting:keptStories"));
    let mut dst = Prefs::default();
    assert!(apply_local(&e, &mut dst, &social(14)));
    assert_eq!(dst.kept_stories.len(), 1);
    assert!(dst.pinned_media.contains(&"img_1".to_string()));
}

#[test]
fn synced_rosters_are_counted_and_garbage_is_tolerated() {
    let s = social(15);
    let e = vec![
        ("roster:abc".to_string(), vec![1, 2, 3]),
        ("profile:name".to_string(), b"x".to_vec()),
        ("roster:def".to_string(), Vec::new()),
    ];
    assert_eq!(ingest_synced_rosters(&e, &s), 2, "counts every roster entry, verified or not");
    assert_eq!(ingest_synced_rosters(&[], &s), 0);
}

#[test]
fn bool_values_read_the_first_byte() {
    assert_eq!(bool_value(&[1]), Some(true));
    assert_eq!(bool_value(&[0, 1]), Some(false));
    assert_eq!(bool_value(&[2]), Some(false));
    assert_eq!(bool_value(&[]), None);
}
