use haven_ffi::HavenSocial;
use std::fs;

fn hexs(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

const FLEET_SEED_B64: &str = "m6Y5kIP5haqgTbAqsNbnnZfG/2AIxXR0z90fcEDDE0A=";
const B_DEV: &str = "401f6cda9ed29974eb0ef02412de42bbd125c4bf16f7a857f285fe8aeb57af89";

fn peer_key_total(s: &HavenSocial) -> usize {
    let v: serde_json::Value = serde_json::from_slice(&s.export_state()).unwrap();
    v["circles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["peer_epoch_keys"].as_array().map(|a| a.len()).unwrap_or(0))
        .sum()
}

/// A handful of REAL B-device key commits straight off the relay store, with their circle ids.
fn b_commits(limit: usize) -> Vec<(String, Vec<u8>)> {
    let home = std::env::var("HOME").unwrap();
    let store = format!(
        "{home}/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/haven-relay-store/haven/mailbox"
    );
    let mut out = Vec::new();
    for circ in fs::read_dir(&store).unwrap().flatten() {
        if !circ.path().is_dir() {
            continue;
        }
        let cid = circ.file_name().to_string_lossy().replace("%3A", ":");
        let mut n = 0;
        for e in fs::read_dir(circ.path()).unwrap().flatten() {
            if !e.path().is_file() {
                continue;
            }
            let Ok(b) = fs::read(e.path()) else { continue };
            if b.first() != Some(&0x03) {
                continue;
            }
            let Ok(env) = serde_json::from_slice::<serde_json::Value>(&b[1..]) else { continue };
            let snd = hexs(
                &env["sender"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u8).collect::<Vec<u8>>(),
            );
            if snd != B_DEV {
                continue;
            }
            out.push((cid.clone(), b));
            n += 1;
            if n >= 2 {
                break;
            }
        }
        if out.len() >= limit {
            break;
        }
    }
    out
}

fn engine() -> (std::sync::Arc<HavenSocial>, Vec<u8>) {
    let home = std::env::var("HOME").unwrap();
    let root = format!("{home}/Library/Application Support/Haven/qa-matrix");
    let state = fs::read(format!("{root}/haven_social_state.bin")).unwrap();
    let seed = data_encoding::BASE64.decode(FLEET_SEED_B64.as_bytes()).unwrap();
    let dr: serde_json::Value =
        serde_json::from_slice(&fs::read(format!("{root}/device-roster.json")).unwrap()).unwrap();
    let dev_seed: Vec<u8> =
        dr["device_seed"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u8).collect();
    let s = HavenSocial::new(seed).unwrap();
    s.import_state(state);
    (s, dev_seed)
}

#[test]
fn ok_false_is_memoized_and_never_reevaluated() {
    let commits = b_commits(6);
    eprintln!("replaying {} real B-device key commits", commits.len());

    // CONTROL: device identity present from the start — the commits apply.
    let (ctl, dev_seed) = engine();
    assert!(ctl.use_device_identity(dev_seed.clone()));
    let before = peer_key_total(&ctl);
    let mut applied = 0;
    for (cid, b) in &commits {
        if matches!(ctl.receive(cid.clone(), b.clone()), Ok(true)) {
            applied += 1;
        }
    }
    eprintln!("CONTROL  (device set first): Ok(true)={applied}  peer_keys {before} -> {}", peer_key_total(&ctl));

    // POISONED: one attempt while the device identity is not yet adopted (open cannot succeed) —
    // exactly the transient the engine's "leave it UNSEEN and retry" path is built for. Then adopt
    // the device identity and re-offer the SAME bytes, over and over, like the 120s retry does.
    let (bad, dev_seed2) = engine();
    let before = peer_key_total(&bad);
    let mut first_pass_true = 0;
    for (cid, b) in &commits {
        if matches!(bad.receive(cid.clone(), b.clone()), Ok(true)) {
            first_pass_true += 1;
        }
    }
    assert!(bad.use_device_identity(dev_seed2)); // the condition that blocked it is now GONE
    let mut retry_true = 0;
    for _ in 0..5 {
        for (cid, b) in &commits {
            if matches!(bad.receive(cid.clone(), b.clone()), Ok(true)) {
                retry_true += 1;
            }
        }
    }
    eprintln!(
        "POISONED (one attempt before device adopt): first-pass Ok(true)={first_pass_true}, \
         5 retries AFTER the blocker cleared Ok(true)={retry_true}, peer_keys {before} -> {}",
        peer_key_total(&bad)
    );
}
