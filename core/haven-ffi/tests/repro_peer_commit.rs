//! OFFLINE REPLAY HARNESS (diagnostic, not a CI gate).
//!
//! Replays the QA relay's REAL mailbox blobs into a fresh core seeded with the fleet seed and the
//! desktop leg's exact persisted state, then reports peer epoch keys / pending / feed before and
//! after. It answers one question in ~3 minutes instead of a 20-minute E2E run: is the desktop's
//! peer blackout caused by MISSING state (members / rosters), or by the engine never re-evaluating
//! a commit it already owns everything to apply?
//!
//! Measured 2026-07-24 against the live fleet: peer_epoch_keys 0 -> 4 on 8/10 circles and the feed
//! grew on 5 of them, from the desktop's OWN persisted state. Nothing was missing.
//!
//! SKIPS (passes) when the QA fleet paths are absent, so it is inert on CI and other machines.
use std::fs;
use haven_ffi::HavenSocial;

const FLEET_SEED_B64: &str = "m6Y5kIP5haqgTbAqsNbnnZfG/2AIxXR0z90fcEDDE0A=";

fn circle_stats(s: &HavenSocial) -> Vec<(String, usize, usize)> {
    let v: serde_json::Value = serde_json::from_slice(&s.export_state()).unwrap();
    v["circles"].as_array().unwrap().iter().map(|c| (
        c["id"].as_str().unwrap_or_default().chars().take(18).collect::<String>(),
        c["peer_epoch_keys"].as_array().map(|a| a.len()).unwrap_or(0),
        c["pending_epoch"].as_array().map(|a| a.len()).unwrap_or(0),
    )).collect()
}

#[test]
fn replay_relay_mailbox_against_desktop_state() {
    let Ok(home) = std::env::var("HOME") else { return };
    let state_path = format!("{home}/Library/Application Support/Haven/qa-matrix/haven_social_state.bin");
    let store = format!(
        "{home}/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/haven-relay-store/haven/mailbox"
    );
    let (Ok(state), true) = (fs::read(&state_path), fs::metadata(&store).is_ok()) else {
        eprintln!("qa fleet state not present — skipping replay harness");
        return;
    };
    let seed = data_encoding::BASE64.decode(FLEET_SEED_B64.as_bytes()).unwrap();
    let s = HavenSocial::new(seed).unwrap();
    s.import_state(state);
    let now = 1784949000000u64;
    let before: Vec<usize> = s.circles().iter().map(|c| s.feed(c.id.clone(), now, None).len()).collect();
    eprintln!("== BEFORE ==");
    for (id, pk, pend) in circle_stats(&s) {
        eprintln!("  {id:20} peer_keys={pk} pending={pend}");
    }
    // Rosters, then key commits, then epoch events — the order the mailbox ranker aims for.
    for c in s.circles() {
        let dir = format!("{store}/{}", c.id.replace(':', "%3A"));
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        let mut blobs: Vec<Vec<u8>> = rd.flatten().filter(|e| e.path().is_file())
            .filter_map(|e| fs::read(e.path()).ok()).filter(|b| !b.is_empty()).collect();
        blobs.sort_by_key(|b| b[0]);
        for tag in [0x04u8, 0x03, 0x02] {
            for b in blobs.iter().filter(|b| b[0] == tag) {
                let _ = s.receive(c.id.clone(), b.clone());
            }
        }
    }
    eprintln!("== AFTER ==");
    let circles = s.circles();
    for (i, (id, pk, pend)) in circle_stats(&s).into_iter().enumerate() {
        let f = s.feed(circles[i].id.clone(), now, None).len();
        eprintln!("  {id:20} peer_keys={pk} pending={pend} feed {} -> {f}", before[i]);
    }
}
