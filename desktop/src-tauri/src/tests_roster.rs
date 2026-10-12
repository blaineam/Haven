//! Device-roster behaviour: key minting, primary protection, revocation, signing and ordering.

use super::*;
use crate::covtest_util::tmp_paths;

fn account() -> (Vec<u8>, String, Vec<u8>) {
    let a = haven_ffi::Account::from_seed(vec![5u8; 32]).unwrap();
    (a.public_bundle(), a.node_id_hex(), a.secret_seed())
}

fn other_device(n: u8) -> (Vec<u8>, String) {
    let a = haven_ffi::Account::from_seed(vec![n; 32]).unwrap();
    (a.public_bundle(), a.node_id_hex())
}

#[test]
fn a_device_key_is_minted_once_and_is_stable() {
    let paths = tmp_paths();
    let r1 = DeviceRoster::load(&paths);
    assert_eq!(r1.device_seed.len(), 32);
    let r2 = DeviceRoster::load(&paths);
    assert_eq!(r1.device_seed, r2.device_seed, "second load reads the saved key");
    assert_eq!(r1.device_node_hex(), r2.device_node_hex());
    assert_eq!(r1.device_node_hex().len(), 64);
    assert!(!r1.device_bundle().is_empty());
    assert!(DeviceRoster::device_name().ends_with(" desktop"));
    assert!(!r1.is_enabled() && !r1.is_authorized());
    // A corrupt file is replaced by a fresh key rather than panicking.
    std::fs::write(DeviceRoster::file(&paths), b"{{").unwrap();
    assert_eq!(DeviceRoster::load(&paths).device_seed.len(), 32);
}

#[test]
fn enabling_registers_the_primary_idempotently() {
    let (bundle, hex, _) = account();
    let mut r = DeviceRoster::load(&tmp_paths());
    r.enable(&bundle, &hex);
    r.enable(&bundle, &hex);
    assert_eq!(r.entries.len(), 1);
    assert_eq!(r.primary_hex, hex);
    assert!(r.entries[&hex].is_primary);
}

#[test]
fn the_primary_cannot_be_revoked_but_linked_devices_can() {
    let (bundle, hex, seed) = account();
    let (dbundle, dhex) = other_device(6);
    let mut r = DeviceRoster::load(&tmp_paths());
    r.enable(&bundle, &hex);
    assert!(!r.revoke(&hex), "never the master key");
    assert!(r.entries.contains_key(&hex));

    let cred = r.add_linked_device(&dbundle, &dhex, "Laptop", &seed, 100);
    assert!(cred.is_some_and(|c| !c.is_empty()), "linking returns a credential");
    assert_eq!(r.entries.len(), 2);
    assert!(r.revoke(&dhex));
    assert!(r.revoke(&dhex), "revoking twice is harmless");
    assert_eq!(r.revoked, vec![dhex.clone()], "recorded once");
    assert!(!r.entries.contains_key(&dhex));

    // Re-linking a revoked device lifts the revocation.
    r.add_linked_device(&dbundle, &dhex, "Laptop", &seed, 200);
    assert!(r.revoked.is_empty());
    assert!(r.entries.contains_key(&dhex));
}

#[test]
fn resigning_bumps_the_version_and_issues_one_credential_per_active_device() {
    let (bundle, hex, seed) = account();
    let (d1b, d1h) = other_device(7);
    let (d2b, d2h) = other_device(8);
    let mut r = DeviceRoster::load(&tmp_paths());
    r.enable(&bundle, &hex);
    r.add_linked_device(&d1b, &d1h, "One", &seed, 1);
    r.add_linked_device(&d2b, &d2h, "Two", &seed, 1);
    let (list, creds) = r.resign(&seed, 10).expect("signs");
    assert!(!list.is_empty());
    assert_eq!(creds.len(), 3);
    assert_eq!(r.version, 1);
    assert!(r.is_enabled());
    r.revoke(&d2h);
    let (_, creds) = r.resign(&seed, 11).unwrap();
    assert_eq!(creds.len(), 2, "revoked devices get no credential");
    assert_eq!(r.version, 2);
    assert!(r.resign(&[1, 2, 3], 12).is_none(), "a bad seed cannot sign a roster");
}

#[test]
fn device_list_orders_primary_first_and_marks_this_device() {
    let (bundle, hex, seed) = account();
    let (d1b, d1h) = other_device(9);
    let mut r = DeviceRoster::load(&tmp_paths());
    r.enable(&bundle, &hex);
    let me = r.device_node_hex();
    r.add_linked_device(&r.device_bundle(), &me, "Zed", &seed, 1);
    r.add_linked_device(&d1b, &d1h, "Alpha", &seed, 1);
    let devs = r.devices(&hex);
    assert_eq!(devs.len(), 3);
    assert!(devs[0].is_primary && devs[0].is_this_device, "primary entry is this account's master");
    assert_eq!(devs[1].name, "Alpha", "then alphabetical");
    assert_eq!(devs[2].name, "Zed");
    assert!(devs[2].is_this_device && !devs[1].is_this_device);
}

#[test]
fn stepping_down_forgets_everything_reversibly() {
    let (bundle, hex, seed) = account();
    let mut r = DeviceRoster::load(&tmp_paths());
    r.enable(&bundle, &hex);
    r.resign(&seed, 1);
    r.credential = Some(vec![1]);
    r.step_down();
    assert!(!r.is_enabled() && !r.is_authorized());
    assert!(r.entries.is_empty() && r.primary_hex.is_empty() && r.revoked.is_empty());
    assert_eq!(r.device_seed.len(), 32, "the device's own key survives");
    r.enable(&bundle, &hex);
    assert_eq!(r.entries.len(), 1, "enabling again works");
}

#[test]
fn roster_state_persists() {
    let paths = tmp_paths();
    let (bundle, hex, seed) = account();
    let mut r = DeviceRoster::load(&paths);
    r.enable(&bundle, &hex);
    r.resign(&seed, 1);
    r.save(&paths).unwrap();
    let back = DeviceRoster::load(&paths);
    assert_eq!(back.version, 1);
    assert_eq!(back.primary_hex, hex);
    assert_eq!(back.entries.len(), 1);
}
