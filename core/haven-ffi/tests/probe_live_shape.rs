use haven_ffi::HavenSocial;
use std::fs;

fn hexs(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

const FLEET_SEED_B64: &str = "m6Y5kIP5haqgTbAqsNbnnZfG/2AIxXR0z90fcEDDE0A=";
const B_DEV: &str = "401f6cda9ed29974eb0ef02412de42bbd125c4bf16f7a857f285fe8aeb57af89";
const B_ACCT: &str = "fe263256608cde2cf4ee266e3ba35ad972db22fa13bd114b38999b03673e1daf";

fn peer_key_total(s: &HavenSocial) -> usize {
    let blob = s.export_state();
    let v: serde_json::Value = serde_json::from_slice(&blob).unwrap();
    v["circles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["peer_epoch_keys"].as_array().map(|a| a.len()).unwrap_or(0))
        .sum()
}

/// Replay the relay mailbox in the SAME sorted order the relay LIST returns, through an engine
/// built exactly like the desktop's `Engine::new` (account seed, import, device identity, both
/// 1.0.7 switches ON). `mls` / `retire` toggle the two non-persisted switches.
fn run(mls: bool, retire: bool, label: &str) {
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
    assert!(s.use_device_identity(dev_seed));
    let _ = s.register_device(s.my_device_bundle(), "probe-mac".into(), 1784806890);
    s.set_mls_keying(mls);
    s.set_seed_drop_retire(retire);
    eprintln!(
        "== {label} (mls={mls} retire={retire}) acct={} dev={} peer_keys_before={}",
        &s.my_node_hex()[..12],
        &s.my_device_node_hex()[..12],
        peer_key_total(&s)
    );

    let store = format!(
        "{home}/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/haven-relay-store/haven/mailbox"
    );
    let mut b_true = 0usize;
    let mut b_false = 0usize;
    let mut b_err = 0usize;
    for c in s.circles() {
        let dir = format!("{store}/{}", c.id.replace(':', "%3A"));
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        let mut names: Vec<String> = rd
            .flatten()
            .filter(|e| e.path().is_file())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        names.sort(); // exactly what the relay LIST hands back
        names.truncate(60); // the head window the desktop's 48-per-pass budget actually reaches
        for n in names {
            let Ok(b) = fs::read(format!("{dir}/{n}")) else { continue };
            if b.is_empty() {
                continue;
            }
            let is_b_commit = b[0] == 0x03
                && serde_json::from_slice::<serde_json::Value>(&b[1..])
                    .ok()
                    .and_then(|e| {
                        e["sender"].as_array().map(|a| {
                            hexs(&a.iter().map(|x| x.as_u64().unwrap() as u8).collect::<Vec<u8>>())
                        })
                    })
                    .map(|h| h == B_DEV || h == B_ACCT)
                    .unwrap_or(false);
            let r = s.receive(c.id.clone(), b);
            if is_b_commit {
                match r {
                    Ok(true) => b_true += 1,
                    Ok(false) => b_false += 1,
                    Err(_) => b_err += 1,
                }
            }
        }
    }
    eprintln!(
        "   B commits: Ok(true)={b_true} Ok(false)={b_false} Err={b_err}; peer_keys_after={}",
        peer_key_total(&s)
    );
}

#[test]
fn live_shape_replay() {
    run(true, true, "LIVE SHAPE (desktop Engine::new)");
    run(false, false, "switches OFF");
}
