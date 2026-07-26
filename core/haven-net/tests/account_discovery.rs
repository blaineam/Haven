//! **Live round-trip: account → device discovery over the public pkarr directory.**
//!
//! This is the mechanism that makes a shared relay optional. A contact holds my ACCOUNT id (that
//! is what an invite/QR carries) but has to dial my DEVICE ids, and both ways of learning those —
//! my signed roster, an invite `?d=` hint — need a route to already exist. Two peers with no relay
//! in common therefore had no route at all, even with both online and iroh perfectly able to
//! hole-punch between them. Publishing the mapping under the account key closes the loop.
//!
//! The encoding half is unit-tested in `accountdiscovery`; what can only be proven here is that the
//! record actually survives a real publish → real resolve against the n0 pkarr servers, under an
//! ARBITRARY account key (not the endpoint's own key — the whole point is that the lookup key is
//! the account, while the endpoint dialing is a device).
//!
//! `#[ignore]` because it needs the network and the publish takes a few seconds to become
//! resolvable. Run it deliberately:
//!
//! ```text
//! cargo test -p haven-net --test account_discovery -- --ignored --nocapture
//! ```

use std::time::Duration;

use rand::RngCore;

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

#[tokio::test]
#[ignore = "network: publishes to and reads from the public pkarr servers"]
async fn account_record_round_trips_through_the_public_directory() {
    // A throwaway ACCOUNT key, distinct from the endpoint's own key — exactly the production shape
    // (the account is an identity, the endpoint is a device).
    let mut account_seed = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut account_seed);
    let account_hex = hex(
        ed25519_dalek::SigningKey::from_bytes(&account_seed)
            .verifying_key()
            .as_bytes(),
    );

    // Two plausible device ids to advertise. Their bytes never have to correspond to live nodes:
    // this test is about the DIRECTORY entry, not about dialing what it points at.
    let devices: Vec<String> = (1u8..=2)
        .map(|i| {
            let mut s = [0u8; 32];
            rand::thread_rng().fill_bytes(&mut s);
            s[0] = i;
            hex(ed25519_dalek::SigningKey::from_bytes(&s).verifying_key().as_bytes())
        })
        .collect();

    let node = haven_net::Node::spawn([7u8; 32], std::sync::Arc::new(|_, _| {}))
        .await
        .expect("spawn node");

    node.publish_account_devices(&account_seed, &devices)
        .expect("publish account devices");

    // The publisher writes in the background and the record needs a moment to be servable. Poll
    // rather than sleeping one long fixed interval, so a fast answer finishes fast.
    let mut got: Vec<String> = Vec::new();
    for _ in 0..20 {
        tokio::time::sleep(Duration::from_secs(2)).await;
        if let Ok(v) = node.resolve_account_devices(&account_hex).await {
            if !v.is_empty() {
                got = v;
                break;
            }
        }
    }
    node.shutdown().await;

    assert_eq!(got, devices, "the directory must return exactly what we published, in order");
}

#[tokio::test]
#[ignore = "network: reads from the public pkarr servers"]
async fn an_account_that_never_published_resolves_empty_not_an_error() {
    // Every install older than this feature has no record. That MUST read as "no hint available"
    // (callers keep every existing dial path) and never as an error or as "this account has no
    // devices" — the difference between additive discovery and a regression.
    let mut seed = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut seed);
    let unknown = hex(ed25519_dalek::SigningKey::from_bytes(&seed).verifying_key().as_bytes());

    let node = haven_net::Node::spawn([9u8; 32], std::sync::Arc::new(|_, _| {}))
        .await
        .expect("spawn node");
    let got = node.resolve_account_devices(&unknown).await;
    node.shutdown().await;

    assert!(
        matches!(&got, Ok(v) if v.is_empty()),
        "unpublished account must resolve to an empty list, got {got:?}"
    );
}
