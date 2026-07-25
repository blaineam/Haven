//! Read-only field probe: can THIS desktop open peer B's KeyCommits at the crypto layer?
//! Touches no product code; reads live QA state + the stub relay store.

use haven_p2p::device::DeviceCredential;
use haven_p2p::groupkey::open_key_commit;
use haven_p2p::identity::{HavenId, Identity};
use haven_p2p::social::SealedEnvelope;
use std::fs;

fn hexs(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn json_bytes(v: &serde_json::Value) -> Vec<u8> {
    v.as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u8).collect()
}

#[test]
fn probe_open_b_keycommit() {
    let home = std::env::var("HOME").unwrap();
    let root = format!("{home}/Library/Application Support/Haven/qa-matrix");

    // 1. desktop DEVICE identity (device-roster.json seed)
    let dr: serde_json::Value =
        serde_json::from_slice(&fs::read(format!("{root}/device-roster.json")).unwrap()).unwrap();
    let dseed: [u8; 32] = json_bytes(&dr["device_seed"]).try_into().unwrap();
    let dev = Identity::from_seed(&dseed);
    eprintln!("device id   = {}", hexs(&dev.public().node_id_bytes()));

    // 2. desktop ACCOUNT identity (fleet seed)
    let fleet = fs::read_to_string(
        "/Users/blainemiller/Documents/mine/Personal/Apps/Haven/build/e2e-2026-07-25-02-59/fleet-seed.txt",
    )
    .unwrap();
    let b64 = fleet.trim().trim_start_matches("haven-seed:");
    let aseed: [u8; 32] = data_encoding::BASE64.decode(b64.as_bytes()).unwrap().try_into().unwrap();
    let acct = Identity::from_seed(&aseed);
    eprintln!("account id  = {}", hexs(&acct.public().node_id_bytes()));

    // 3. B's account bundle + B's device bundle, from the persisted rosters
    let state: serde_json::Value =
        serde_json::from_slice(&fs::read(format!("{root}/haven_social_state.bin")).unwrap()).unwrap();
    let b_acct_hex = "fe263256608cde2cf4ee266e3ba35ad972db22fa13bd114b38999b03673e1daf";
    let mut b_acct: Option<HavenId> = None;
    let mut b_dev: Option<HavenId> = None;
    for r in state["device_rosters"].as_array().unwrap() {
        let bundle = json_bytes(&r[0]);
        if hexs(&bundle[..32]) != b_acct_hex {
            continue;
        }
        b_acct = HavenId::from_bytes(&bundle).ok();
        for c in r[2].as_array().unwrap() {
            if let Ok(cred) = DeviceCredential::from_bytes(&json_bytes(c)) {
                eprintln!(
                    "B credential -> device {} verify_vs_account={:?}",
                    hexs(&cred.device.node_id_bytes()),
                    cred.verify(b_acct.as_ref().unwrap()).is_ok()
                );
                b_dev = Some(cred.device.clone());
            }
        }
    }
    let b_acct = b_acct.expect("B account bundle");

    // 4. every B-signed KeyCommit on the stub relay: try to open with device, then account
    let store = format!(
        "{home}/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/haven-relay-store/haven/mailbox"
    );
    let (mut dev_ok, mut acct_ok, mut both_fail, mut total) = (0, 0, 0, 0);
    let mut sample: Vec<String> = vec![];
    for c in fs::read_dir(&store).unwrap().flatten() {
        if !c.path().is_dir() {
            continue;
        }
        for e in fs::read_dir(c.path()).unwrap().flatten() {
            if !e.path().is_file() {
                continue;
            }
            let Ok(b) = fs::read(e.path()) else { continue };
            if b.first() != Some(&0x03) {
                continue;
            }
            let Ok(env) = SealedEnvelope::from_bytes(&b[1..]) else { continue };
            let sh = env.sender_hex();
            let committer = if sh == b_acct_hex {
                b_acct.clone()
            } else if Some(&sh) == b_dev.as_ref().map(|d| hexs(&d.node_id_bytes())).as_ref() {
                b_dev.clone().unwrap()
            } else {
                continue;
            };
            total += 1;
            let d = open_key_commit(&dev, &committer, &env);
            let a = open_key_commit(&acct, &committer, &env);
            match (&d, &a) {
                (Ok(_), _) => dev_ok += 1,
                (_, Ok(_)) => acct_ok += 1,
                (Err(de), Err(ae)) => {
                    both_fail += 1;
                    if sample.len() < 6 {
                        sample.push(format!("sender={} device_err={de} account_err={ae}", &sh[..16]));
                    }
                }
            }
        }
    }
    eprintln!("B KeyCommits total={total} device_open_ok={dev_ok} account_open_ok={acct_ok} BOTH_FAIL={both_fail}");
    for s in sample {
        eprintln!("   {s}");
    }
}
