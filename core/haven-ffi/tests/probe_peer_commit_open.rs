use haven_ffi::HavenSocial;
use std::fs;

fn hexs(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn peer_keys(s: &HavenSocial) -> Vec<(String, usize, usize)> {
    let blob = s.export_state();
    let v: serde_json::Value = serde_json::from_slice(&blob).unwrap();
    v["circles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| {
            (
                c["id"].as_str().unwrap().chars().take(22).collect::<String>(),
                c["peer_epoch_keys"].as_array().map(|a| a.len()).unwrap_or(0),
                c["pending_epoch"].as_array().map(|a| a.len()).unwrap_or(0),
            )
        })
        .collect()
}

#[test]
fn probe_peer_commit_open_with_device_identity() {
    let home = std::env::var("HOME").unwrap();
    let root = format!("{home}/Library/Application Support/Haven/qa-matrix");
    let state = fs::read(format!("{root}/haven_social_state.bin")).unwrap();
    let v: serde_json::Value = serde_json::from_slice(&state).unwrap();

    // My account PUBLIC bundle, straight out of the persisted device_rosters.
    let my_acct_hex = "b2d704e821e6aeaa298e476f0f07ac150b8591b97dbac962ada38c09e964822f";
    let mut acct_bundle: Vec<u8> = Vec::new();
    for r in v["device_rosters"].as_array().unwrap() {
        let b: Vec<u8> =
            r[0].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u8).collect();
        if hexs(&b[..32]) == my_acct_hex {
            acct_bundle = b;
        }
    }
    assert!(!acct_bundle.is_empty(), "account bundle not found in state");

    // The desktop's DEVICE seed (device-roster.json), so `st.device` is the real 71ebb247 device.
    let dr: serde_json::Value =
        serde_json::from_slice(&fs::read(format!("{root}/device-roster.json")).unwrap()).unwrap();
    let dev_seed: Vec<u8> =
        dr["device_seed"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u8).collect();

    let s = HavenSocial::new_seedless(acct_bundle, dev_seed).unwrap();
    eprintln!("device node hex = {}", s.my_device_node_hex());
    s.import_state(state);

    eprintln!("== BEFORE ==");
    for (id, pk, pend) in peer_keys(&s) {
        eprintln!("  {id:24} peer_keys={pk} pending={pend}");
    }

    let store = format!(
        "{home}/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/haven-relay-store/haven/mailbox"
    );
    let b_dev = "401f6cda9ed29974eb0ef02412de42bbd125c4bf16f7a857f285fe8aeb57af89";
    let b_acct = "fe263256608cde2cf4ee266e3ba35ad972db22fa13bd114b38999b03673e1daf";

    let mut first_true = 0usize;
    let mut first_false = 0usize;
    let mut first_err = 0usize;
    let mut second_pass_changed = 0usize;
    for c in s.circles() {
        let dir = format!("{store}/{}", c.id.replace(':', "%3A"));
        let Ok(rd) = fs::read_dir(&dir) else {
            eprintln!("no relay dir for {}", c.id.chars().take(22).collect::<String>());
            continue;
        };
        let mut n = 0;
        for e in rd.flatten() {
            if !e.path().is_file() {
                continue;
            }
            let Ok(b) = fs::read(e.path()) else { continue };
            if b.first() != Some(&0x03) {
                continue;
            }
            let Ok(env) = serde_json::from_slice::<serde_json::Value>(&b[1..]) else { continue };
            let sender: Vec<u8> =
                env["sender"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u8).collect();
            let sh = hexs(&sender);
            if sh != b_dev && sh != b_acct {
                continue;
            }
            n += 1;
            if n > 3 {
                break; // a few per circle is enough
            }
            let r1 = s.receive(c.id.clone(), b.clone());
            let r2 = s.receive(c.id.clone(), b.clone()); // same bytes again — dedupe probe
            match &r1 {
                Ok(true) => first_true += 1,
                Ok(false) => first_false += 1,
                Err(_) => first_err += 1,
            }
            if matches!(r2, Ok(true)) {
                second_pass_changed += 1;
            }
            eprintln!(
                "  {} sender={} first={:?} second={:?}",
                c.id.chars().take(18).collect::<String>(),
                &sh[..16],
                r1,
                r2
            );
        }
    }
    eprintln!(
        "B-authored commits: first Ok(true)={first_true} Ok(false)={first_false} Err={first_err}, second-call Ok(true)={second_pass_changed}"
    );

    eprintln!("== AFTER ==");
    for (id, pk, pend) in peer_keys(&s) {
        eprintln!("  {id:24} peer_keys={pk} pending={pend}");
    }
}
