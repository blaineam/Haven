use haven_ffi::HavenSocial;
use std::fs;

fn main() {
    let state = fs::read("/tmp/and-social.bin").unwrap();
    let account = fs::read("/tmp/and-account-bundle.bin").unwrap();
    let device_seed = fs::read("/tmp/and-device-seed.bin").unwrap();
    let commit = fs::read("/tmp/ios-keycommit.bin").unwrap();
    let acct_hex: String = account[..32].iter().map(|b| format!("{b:02x}")).collect();
    println!("account node {acct_hex}");
    let eng = HavenSocial::new_seedless(account, device_seed).expect("seedless");
    println!("me={} device={}", eng.my_node_hex(), eng.my_device_node_hex());
    eng.import_state(state);
    match eng.receive("default".into(), commit.clone()) {
        Ok(v) => println!("receive keycommit => {v}"),
        Err(e) => println!("receive keycommit err => {e:?}"),
    }
    // also try with account identity if we can derive - skip
    let store = std::path::Path::new("/Users/blainemiller/Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/haven-relay-store/haven/mailbox/default");
    let mut ok=0; let mut fail_by_tag = std::collections::BTreeMap::new();
    for ent in fs::read_dir(store).unwrap() {
        let p = ent.unwrap().path();
        if !p.is_file() { continue; }
        let b = fs::read(&p).unwrap();
        if b.is_empty() { continue; }
        let tag = b[0];
        match eng.receive("default".into(), b.clone()) {
            Ok(true) => { ok+=1; println!("OK tag={tag} {}", p.file_name().unwrap().to_string_lossy()); }
            Ok(false) => { *fail_by_tag.entry(tag).or_insert(0) += 1; }
            Err(e) => println!("ERR tag={tag} {e:?}"),
        }
    }
    println!("summary ok={ok} false_by_tag={fail_by_tag:?}");
    let feed = eng.feed("default".into(), 1_784_700_000_000, None);
    println!("feed {}", feed.len());
    for it in feed.iter().take(20) {
        println!("  me={} author={} body={}", it.is_me, it.author_short, it.body.chars().take(50).collect::<String>());
    }
}
