//! Live device-to-device delivery (D16 Phase 4b), and the fallback that makes it safe to ship.
//!
//! Two proofs, in the order they matter:
//!
//! 1. `live_delivery_reaches_a_sibling_device_with_no_relay_in_the_picture` — the user's phone and
//!    Mac are both online; a post authored on the phone lands on the Mac over a direct iroh path.
//!    There is **no relay node anywhere in that test**: nothing to store it, nothing to forward it.
//!    So the sibling can only have gotten it live.
//!
//! 2. `a_dead_direct_path_falls_back_to_the_mailbox` — the same push with the sibling offline. The
//!    live attempt reports it unreached (promptly — it must not hang the caller behind iroh's ~30s
//!    dial timeout), the caller's **unconditional** mailbox put runs exactly as it does today, and
//!    the sibling gets the identical event when it comes online. Live delivery removed nothing.
//!
//! Both devices run under **per-device transport seeds** (never the account seed, which is a contact
//! handle that resolves to no endpoint) while sealing stays account-based — so either device opens
//! the other's content with the shared account identity. That is the multi-device shape these tests
//! exist to hold in place.

use std::sync::Arc;

use haven_net::blobstore::{BlobClient, BlobServer};
use haven_net::livedelivery::{deliver_to_own_devices, TOTAL_BUDGET};
use haven_net::Node;
use p2pcore::identity::Identity;
use p2pcore::social::{open_event, seal_event, Event, EventKind, Group, SealedEnvelope};
use tokio::time::{timeout, Duration};

/// A post the user authors on one of their devices, sealed to their circle.
fn authored_post(account: &Identity, group: &Group, body: &str) -> (Event, Vec<u8>) {
    let event = Event::new(
        &account.public().node_id_bytes(),
        11,
        EventKind::Post {
            body: body.into(),
            media: vec![],
            music: None,
            retention_secs: None,
            story: false,
            mute_video: false,
        },
    );
    let sealed = seal_event(account, group, &event).unwrap().to_bytes();
    (event, sealed)
}

#[tokio::test]
async fn live_delivery_reaches_a_sibling_device_with_no_relay_in_the_picture() {
    // ONE account, TWO devices. The account seed signs/seals; each device dials under its own seed.
    let account = Identity::generate();
    let friend = Identity::generate();
    let phone_dev = Identity::generate();
    let mac_dev = Identity::generate();
    let group = Group::new("fam", vec![account.public(), friend.public()]);

    let (event, payload) = authored_post(&account, &group, "posted on my phone 📱");

    // The Mac: a sibling device listening under its own transport id.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let mac = Node::spawn(
        mac_dev.node_secret_bytes(),
        Arc::new(move |_from: [u8; 32], p: Vec<u8>| {
            let _ = tx.send(p);
        }),
    )
    .await
    .unwrap();
    let mac_hex = mac.node_id_hex();

    // The phone: where the post is authored.
    let phone = Node::spawn(phone_dev.node_secret_bytes(), Arc::new(|_: [u8; 32], _: Vec<u8>| {})).await.unwrap();
    let phone_hex = phone.node_id_hex();

    // Same-machine: let the two devices meet over loopback so the push isn't gated on public
    // discovery. Connections are reused bidirectionally, so the phone's push rides this path.
    mac.send(phone.local_dial_addr().await.unwrap(), b"hello-sibling").await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;

    // The roster hands us the Mac twice (in different casing) AND our own id — exactly the kind of
    // list `device_node_ids_for` produces. Dedup + the self-filter must handle it: dialing ourselves
    // is the unbounded path-discovery leak, and a duplicate is a wasted dial.
    let targets = vec![mac_hex.clone(), mac_hex.to_uppercase(), phone_hex.clone()];
    let out = deliver_to_own_devices(&phone, &targets, &payload).await;

    assert_eq!(out.delivered, vec![mac_hex.clone()], "the sibling took the post live, exactly once");
    assert!(out.unreached.is_empty(), "nothing left for the mailbox: {:?}", out.unreached);
    assert!(!out.delivered.contains(&phone_hex), "must never deliver to our own node id");

    // The Mac opens the phone's post with the SHARED ACCOUNT identity. No relay exists in this test,
    // so this payload came off the direct device-to-device path or nowhere at all.
    let received = timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("live delivery timed out")
        .expect("channel closed");
    let env = SealedEnvelope::from_bytes(&received).unwrap();
    let opened = open_event(&account, &account.public(), &env).expect("sibling opens it with the account key");
    assert_eq!(opened, event, "the Mac shows the exact post authored on the phone");

    phone.close().await;
    mac.close().await;
}

/// The guarantee that lets live delivery ship: it is strictly additive. Kill the direct path and the
/// event still arrives by the route it has always taken.
#[tokio::test]
async fn a_dead_direct_path_falls_back_to_the_mailbox() {
    let account = Identity::generate();
    let friend = Identity::generate();
    let phone_dev = Identity::generate();
    let mac_dev = Identity::generate(); // valid id, NOBODY is running it — the Mac is asleep
    let relay_id = Identity::generate();
    // The phone's STORE client takes its OWN key, never `phone_dev` — a second iroh endpoint under a
    // key an endpoint is already bound to steals that node's DERP registration and starts refusing
    // inbound (the same-key-second-endpoint bug). The shipping app avoids this by reusing the node's
    // endpoint via `Node::blob_client`; here a distinct key keeps the loopback dial deterministic
    // without leaning on public discovery. Which key uploads is immaterial to the claim under test.
    let phone_store = Identity::generate();
    let group = Group::new("fam", vec![account.public(), friend.public()]);

    let (event, payload) = authored_post(&account, &group, "posted while my Mac was asleep 💤");
    // The canonical mailbox key layout (`haven/mailbox/<circle>/<content-hash>`) — what the relay
    // parses the circle out of to membership-gate the request.
    let key = format!("haven/mailbox/fam/{}", blake3::hash(&payload).to_hex());

    let store_dir = std::env::temp_dir().join(format!("haven-livedelivery-fallback-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&store_dir);
    let relay = BlobServer::spawn(relay_id.node_secret_bytes(), store_dir.clone()).await.unwrap();
    // The relay gates mailbox keys on circle membership, so authorize the two devices doing the
    // upload/fetch — what the app's `relay_authorize` does for a circle's members + their devices.
    relay.authorize(
        "fam",
        vec![hex32(&phone_store.public().node_id_bytes()), hex32(&mac_dev.public().node_id_bytes())],
        vec![],
    );
    let relay_addr = relay.local_dial_addr().await.unwrap();

    let phone = Node::spawn(phone_dev.node_secret_bytes(), Arc::new(|_: [u8; 32], _: Vec<u8>| {})).await.unwrap();
    let mac_hex = hex32(&mac_dev.public().node_id_bytes());

    // The phone tries the fast path first, as it would for any local change.
    let started = std::time::Instant::now();
    let out = deliver_to_own_devices(&phone, &[mac_hex.clone()], &payload).await;
    let spent = started.elapsed();

    assert!(out.delivered.is_empty(), "an offline sibling cannot have taken it live");
    assert_eq!(out.unreached, vec![mac_hex], "the offline sibling is reported for the mailbox");
    // Bounded: a sleeping device must not hold a user-triggered push behind iroh's ~30s dial timeout.
    assert!(spent < TOTAL_BUDGET + Duration::from_secs(3), "live attempt took {spent:?}; must give up promptly");

    // …and then does what it has ALWAYS done, unconditionally, whatever the live attempt reported.
    let phone_client = BlobClient::connect_addr(phone_store.node_secret_bytes(), relay_addr.clone()).await.unwrap();
    timeout(Duration::from_secs(10), phone_client.put(&key, &payload))
        .await
        .expect("mailbox put timed out")
        .expect("mailbox put failed");

    // The Mac wakes up and polls its mailbox — the pre-existing path, untouched by any of this.
    let mac_client = BlobClient::connect_addr(mac_dev.node_secret_bytes(), relay_addr.clone()).await.unwrap();
    let fetched = timeout(Duration::from_secs(10), mac_client.get(&key))
        .await
        .expect("mailbox get timed out")
        .expect("mailbox get failed")
        .expect("the mailbox held the event the live push could not deliver");

    let env = SealedEnvelope::from_bytes(&fetched).unwrap();
    let opened = open_event(&account, &account.public(), &env).expect("sibling opens it with the account key");
    assert_eq!(opened, event, "the event still arrives in full when the direct path is dead");

    let _ = phone_client.close().await;
    let _ = mac_client.close().await;
    phone.close().await;
    let _ = std::fs::remove_dir_all(&store_dir);
}

fn hex32(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
