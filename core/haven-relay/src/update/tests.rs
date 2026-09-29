//! Updater tests: signatures, the install plan, and an end-to-end run against a local mock
//! "GitHub" serving a signed fake release (download → verify → install → restart signal →
//! probation → rollback / commit).

use super::*;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

const SEED: [u8; 32] = [7u8; 32];
const OTHER_SEED: [u8; 32] = [9u8; 32];
const ASSET: &str = "haven-relay-test-target";

fn pk(seed: &[u8; 32]) -> [u8; 32] {
    sig::public_key(seed)
}

// ── signatures ────────────────────────────────────────────────────────────────────────────────

#[test]
fn signature_good_tampered_wrong_key_and_replays() {
    let bin = b"pretend relay binary".to_vec();
    let text = sig::sign_asset(&SEED, "1.2.0", ASSET, &bin);
    let keys = [pk(&SEED)];
    let h = sig::sha256(&bin);
    assert_eq!(sig::verify(&text, "1.2.0", ASSET, &h, &keys).unwrap(), sig::key_id(&pk(&SEED)));

    // Tampered bytes.
    let mut evil = bin.clone();
    evil[0] ^= 1;
    assert!(sig::verify(&text, "1.2.0", ASSET, &sig::sha256(&evil), &keys).is_err());
    // Wrong key (and a list with a key rotated in still accepts the right one).
    assert!(sig::verify(&text, "1.2.0", ASSET, &h, &[pk(&OTHER_SEED)]).is_err());
    assert!(sig::verify(&text, "1.2.0", ASSET, &h, &[pk(&OTHER_SEED), pk(&SEED)]).is_ok());
    // Cross-asset replay: a valid signature for ANOTHER asset name, even over identical bytes.
    let other_asset = sig::sign_asset(&SEED, "1.2.0", "haven-relay-aarch64-apple-darwin", &bin);
    assert!(sig::verify(&other_asset, "1.2.0", ASSET, &h, &keys).is_err());
    // Version replay: an old version's valid signature served as a new release.
    let old = sig::sign_asset(&SEED, "1.1.0", ASSET, &bin);
    assert!(sig::verify(&old, "1.2.0", ASSET, &h, &keys).is_err());
    // Editing the printed fields to lie doesn't help: the message is rebuilt from expectations.
    let lied = old.replace("version 1.1.0", "version 1.2.0");
    assert!(sig::verify(&lied, "1.2.0", ASSET, &h, &keys).is_err());
    // Garbage.
    assert!(sig::verify("nope", "1.2.0", ASSET, &h, &keys).is_err());
    assert!(sig::parse_sig(&format!("{text}sig 00\n")).is_err(), "duplicate field rejected");
}

#[test]
fn compiled_in_trusted_keys_decode() {
    let keys = sig::trusted_keys();
    assert!(!keys.is_empty(), "at least one release key must be embedded");
    assert_eq!(keys.len(), sig::TRUSTED_KEYS.len(), "every embedded key is valid hex");
    for k in keys {
        assert!(ed25519_dalek::VerifyingKey::from_bytes(&k).is_ok());
    }
}

#[test]
fn build_identity_is_consistent() {
    assert!(Version::parse(VERSION).is_some(), "VERSION must parse: {VERSION}");
    assert!(!TARGET.is_empty());
}

// ── install plan ──────────────────────────────────────────────────────────────────────────────

#[test]
fn install_plan_decisions() {
    let exe = Some(PathBuf::from("/home/u/.local/bin/haven-relay"));
    let base = PlanInputs { install_env: None, supervised: true, exe: exe.clone(), exe_dir_writable: true, manual: false };
    assert_eq!(decide_plan(&base), Plan::InPlace { exe: exe.clone().unwrap(), restart: true });
    assert_eq!(decide_plan(&PlanInputs { install_env: Some("volume".into()), ..base.clone() }), Plan::Volume);
    assert!(matches!(decide_plan(&PlanInputs { install_env: Some("notify".into()), ..base.clone() }), Plan::NotifyOnly(_)));
    assert!(matches!(decide_plan(&PlanInputs { exe_dir_writable: false, ..base.clone() }), Plan::NotifyOnly(_)));
    assert!(matches!(decide_plan(&PlanInputs { supervised: false, ..base.clone() }), Plan::NotifyOnly(_)), "nothing would restart it");
    assert_eq!(
        decide_plan(&PlanInputs { supervised: false, manual: true, ..base.clone() }),
        Plan::InPlace { exe: exe.clone().unwrap(), restart: false }
    );
    assert!(
        matches!(decide_plan(&PlanInputs { exe: Some("/usr/bin/haven-relay".into()), ..base.clone() }), Plan::NotifyOnly(_)),
        "the .deb's binary belongs to apt"
    );
}

// ── mock release server ───────────────────────────────────────────────────────────────────────

type Routes = Arc<Mutex<HashMap<String, Vec<u8>>>>;

/// Minimal HTTP/1.1 server: GET <path> → 200 body, else 404. Returns the base URL.
async fn serve(routes: Routes) -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", l.local_addr().unwrap());
    tokio::spawn(async move {
        loop {
            let Ok((mut s, _)) = l.accept().await else { return };
            let routes = routes.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut tmp = [0u8; 1024];
                while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
                    let Ok(n) = s.read(&mut tmp).await else { return };
                    if n == 0 {
                        return;
                    }
                    buf.extend_from_slice(&tmp[..n]);
                }
                let head = String::from_utf8_lossy(&buf).to_string();
                let path = head.split_whitespace().nth(1).unwrap_or("/").to_string();
                let body = routes.lock().unwrap().get(&path).cloned();
                let resp = match body {
                    Some(b) => {
                        let mut r = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", b.len()).into_bytes();
                        r.extend_from_slice(&b);
                        r
                    }
                    None => b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec(),
                };
                let _ = s.write_all(&resp).await;
                let _ = s.shutdown().await;
            });
        }
    });
    base
}

fn fake_binary(reports: &str) -> Vec<u8> {
    format!("#!/bin/sh\necho \"haven-relay {reports}\"\n").into_bytes()
}

/// Publish one release `tag` with the asset + sig (the sig text given explicitly so tests can
/// serve forged ones).
fn publish(routes: &Routes, base: &str, tags: &[(&str, bool)], asset_bytes: &[u8], sig_text: &str) {
    let mut rels = Vec::new();
    for (tag, pre) in tags {
        rels.push(serde_json::json!({
            "tag_name": tag, "prerelease": pre, "draft": false,
            "assets": [
                {"name": ASSET, "browser_download_url": format!("{base}/dl/{tag}/{ASSET}"), "size": asset_bytes.len()},
                {"name": format!("{ASSET}.sig"), "browser_download_url": format!("{base}/dl/{tag}/{ASSET}.sig"), "size": sig_text.len()},
            ]
        }));
        let mut r = routes.lock().unwrap();
        r.insert(format!("/dl/{tag}/{ASSET}"), asset_bytes.to_vec());
        r.insert(format!("/dl/{tag}/{ASSET}.sig"), sig_text.as_bytes().to_vec());
    }
    routes.lock().unwrap().insert("/releases".into(), serde_json::to_vec(&rels).unwrap());
}

fn tmpdir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("hr-upd-{tag}-{}-{}", std::process::id(), install::now_secs()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn updater(data: &Path, base: &str, current: &str) -> Updater {
    Updater {
        data_dir: data.to_path_buf(),
        channel: Channel::Stable,
        current: Version::parse(current).unwrap(),
        asset_name: Some(ASSET.into()),
        keys: vec![pk(&SEED)],
        list_url: format!("{base}/releases"),
        allow_http: true,
        running_exe: data.join("image-haven-relay"),
    }
}

#[cfg(unix)]
#[tokio::test]
async fn end_to_end_volume_update_probation_rollback_and_never_retry() {
    let routes: Routes = Default::default();
    let base = serve(routes.clone()).await;
    let bin = fake_binary("9.9.9");
    publish(&routes, &base, &[("v9.9.9", false), ("v9.9.10-rc.1", true)], &bin, &sig::sign_asset(&SEED, "9.9.9", ASSET, &bin));
    let data = tmpdir("e2e");
    let up = updater(&data, &base, "1.0.0");
    let dir = install::update_dir(&data);

    // download → verify → install → restart signal
    let o = up.run_once(&Plan::Volume).await.unwrap();
    assert_eq!(o, Outcome::Installed { version: "9.9.9".into(), restart: true });
    let vol = install::volume_bin(&dir);
    assert_eq!(std::fs::read(&vol).unwrap(), bin);
    assert_eq!(install::binary_version(&vol, Duration::from_secs(5)), Version::parse("9.9.9"));
    assert!(install::prefer_volume(&Version::parse("1.0.0").unwrap(), Version::parse("9.9.9").as_ref(), &[]));
    assert_eq!(install::load_state(&dir).pending.unwrap().prev_version, "1.0.0");
    // While on probation, the loop doesn't stack another update on top.
    assert!(matches!(up.run_once(&Plan::Volume).await.unwrap(), Outcome::Disabled(_)));

    // New binary starts (probation) … and fails its health check → rollback.
    assert_eq!(install::startup_gate(&dir, "9.9.9"), Gate::Probation(1));
    assert_eq!(install::rollback_pending(&dir).unwrap().as_deref(), Some("9.9.9"));
    assert!(!vol.exists(), "no previous volume binary → back to the image binary");
    assert!(install::load_state(&dir).bad.contains(&"9.9.9".to_string()));

    // Never retried: the stable channel has nothing else newer.
    assert_eq!(up.run_once(&Plan::Volume).await.unwrap(), Outcome::UpToDate);
    // No staging leftovers.
    let left: Vec<_> = std::fs::read_dir(install::staging_dir(&dir)).unwrap().flatten().collect();
    assert!(left.is_empty(), "staging must be empty, found {left:?}");
    let _ = std::fs::remove_dir_all(&data);
}

#[cfg(unix)]
#[tokio::test]
async fn end_to_end_inplace_update_commits_when_healthy() {
    let routes: Routes = Default::default();
    let base = serve(routes.clone()).await;
    let bin = fake_binary("2.0.0");
    publish(&routes, &base, &[("v2.0.0", false)], &bin, &sig::sign_asset(&SEED, "2.0.0", ASSET, &bin));
    let data = tmpdir("inplace");
    let exe_dir = data.join("bin");
    std::fs::create_dir_all(&exe_dir).unwrap();
    let exe = exe_dir.join("haven-relay");
    std::fs::write(&exe, fake_binary("1.0.0")).unwrap();
    let up = updater(&data, &base, "1.0.0");
    let plan = Plan::InPlace { exe: exe.clone(), restart: true };
    assert_eq!(up.run_once(&plan).await.unwrap(), Outcome::Installed { version: "2.0.0".into(), restart: true });
    assert_eq!(install::binary_version(&exe, Duration::from_secs(5)), Version::parse("2.0.0"));
    assert_eq!(install::binary_version(&exe_dir.join("haven-relay.prev"), Duration::from_secs(5)), Version::parse("1.0.0"));
    let dir = install::update_dir(&data);
    assert_eq!(install::startup_gate(&dir, "2.0.0"), Gate::Probation(1));
    assert!(install::commit(&dir, "2.0.0"));
    assert_eq!(install::load_state(&dir).last_good.as_deref(), Some("2.0.0"));
    assert_eq!(updater(&data, &base, "2.0.0").run_once(&plan).await.unwrap(), Outcome::UpToDate);
    let _ = std::fs::remove_dir_all(&data);
}

#[cfg(unix)]
#[tokio::test]
async fn forged_releases_are_rejected_and_nothing_is_installed() {
    let good = fake_binary("3.0.0");
    let cases: Vec<(&str, Vec<u8>, String)> = vec![
        // Bytes differ from what was signed.
        ("tampered", fake_binary("3.0.0 evil"), sig::sign_asset(&SEED, "3.0.0", ASSET, &good)),
        // Signed by a key the relay doesn't trust.
        ("wrong-key", good.clone(), sig::sign_asset(&OTHER_SEED, "3.0.0", ASSET, &good)),
        // A genuine signature for a different asset.
        ("cross-asset", good.clone(), sig::sign_asset(&SEED, "3.0.0", "haven-relay-other-target", &good)),
        // A genuine signature for a different (older) version.
        ("version-replay", good.clone(), sig::sign_asset(&SEED, "2.9.0", ASSET, &good)),
    ];
    for (name, served, sig_text) in cases {
        let routes: Routes = Default::default();
        let base = serve(routes.clone()).await;
        publish(&routes, &base, &[("v3.0.0", false)], &served, &sig_text);
        let data = tmpdir(name);
        let up = updater(&data, &base, "1.0.0");
        let err = up.run_once(&Plan::Volume).await.unwrap_err().to_string();
        assert!(err.contains("REJECTED"), "{name}: {err}");
        let dir = install::update_dir(&data);
        assert!(!install::volume_bin(&dir).exists(), "{name}: nothing installed");
        let st = install::load_state(&dir);
        assert!(st.pending.is_none() && st.bad.is_empty(), "{name}: a forgery never marks the real version bad");
        let _ = std::fs::remove_dir_all(&data);
    }
}

#[cfg(unix)]
#[tokio::test]
async fn signed_but_mislabelled_binary_is_marked_bad() {
    let routes: Routes = Default::default();
    let base = serve(routes.clone()).await;
    let bin = fake_binary("4.0.0-rc.1"); // claims to be something else
    publish(&routes, &base, &[("v4.0.0", false)], &bin, &sig::sign_asset(&SEED, "4.0.0", ASSET, &bin));
    let data = tmpdir("mislabel");
    let up = updater(&data, &base, "1.0.0");
    assert!(up.run_once(&Plan::Volume).await.is_err());
    let dir = install::update_dir(&data);
    assert!(!install::volume_bin(&dir).exists());
    assert_eq!(install::load_state(&dir).bad, vec!["4.0.0".to_string()]);
    assert_eq!(up.run_once(&Plan::Volume).await.unwrap(), Outcome::UpToDate);
    let _ = std::fs::remove_dir_all(&data);
}

#[tokio::test]
async fn notify_only_and_off_never_download() {
    let routes: Routes = Default::default();
    let base = serve(routes.clone()).await;
    let bin = fake_binary("5.0.0");
    publish(&routes, &base, &[("v5.0.0", false)], &bin, &sig::sign_asset(&SEED, "5.0.0", ASSET, &bin));
    let data = tmpdir("notify");
    let up = updater(&data, &base, "1.0.0");
    let o = up.run_once(&Plan::NotifyOnly("test".into())).await.unwrap();
    assert!(matches!(o, Outcome::Available { ref version, .. } if version == "5.0.0"));
    assert!(!install::volume_bin(&install::update_dir(&data)).exists());
    let off = Updater { channel: Channel::Off, ..updater(&data, &base, "1.0.0") };
    assert!(matches!(off.run_once(&Plan::Volume).await.unwrap(), Outcome::Disabled(_)));
    let _ = std::fs::remove_dir_all(&data);
}

#[tokio::test]
async fn real_source_refuses_non_github_urls() {
    let routes: Routes = Default::default();
    let base = serve(routes.clone()).await;
    let bin = fake_binary("6.0.0");
    publish(&routes, &base, &[("v6.0.0", false)], &bin, &sig::sign_asset(&SEED, "6.0.0", ASSET, &bin));
    let data = tmpdir("nongh");
    let up = Updater { allow_http: false, ..updater(&data, &base, "1.0.0") };
    let client = net::client(true).unwrap(); // reach the mock list, but assets must be on github.com
    let cand = up.check(&client).await.unwrap().unwrap();
    let err = up.fetch_verified(&client, &cand, &install::staging_dir(&install::update_dir(&data))).await.unwrap_err();
    assert!(err.to_string().contains("outside github.com"));
    let _ = std::fs::remove_dir_all(&data);
}
