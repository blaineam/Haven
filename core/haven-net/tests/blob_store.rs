//! The **local-disk media store-and-forward** proof:
//!
//! One node (Alice) seals a media blob to the circle and PUTs it to a relay that stores
//! it on **local disk** over Haven Net (iroh, ALPN `haven/blob/1`). A *different* node
//! (Bob) — who never talked to Alice — GETs the same content-addressed blob from the
//! relay over iroh and opens it with **his own** circle keys. We then assert the relay,
//! which is not a circle member, **cannot decrypt** what it stored: it only ever held
//! opaque ciphertext on disk.
//!
//! This is the headline guarantee: decentralized local-disk mailbox, host is a
//! non-key-holder.

use haven_net::blobstore::{BlobClient, BlobServer};
use p2pcore::identity::Identity;
use p2pcore::social::{open_bytes, seal_bytes, Group, SealedEnvelope};
use tokio::time::{timeout, Duration};

/// Content-address a sealed blob exactly the way the mailbox does: a stable key derived
/// from the sealed bytes, namespaced under the circle's mailbox path.
fn mailbox_key(circle: &str, sealed: &[u8]) -> String {
    let hash = blake3::hash(sealed);
    format!("mailbox/{circle}/{}", hash.to_hex())
}

#[tokio::test]
async fn sealed_blob_put_to_local_disk_relay_is_fetched_by_another_node_and_relay_cannot_decrypt() {
    // The circle: Alice + Bob hold the keys. The relay does NOT (it is not a member).
    let alice = Identity::generate();
    let bob = Identity::generate();
    let relay_id = Identity::generate();
    let group = Group::new("fam", vec![alice.public(), bob.public()]);

    // Alice seals a media blob to the whole circle.
    let plaintext = b"\x89PNG\r\n\x1a\n ...pretend this is a family photo... \xff\xd8\xff";
    let sealed = seal_bytes(&alice, &group, plaintext).unwrap().to_bytes();
    let key = mailbox_key("fam", &sealed);

    // The relay serves a LOCAL DIRECTORY over iroh. Nothing is public; no rclone, no S3.
    let store_dir =
        std::env::temp_dir().join(format!("haven-relay-blobtest-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&store_dir);
    let server = BlobServer::spawn(relay_id.node_secret_bytes(), store_dir.clone())
        .await
        .unwrap();
    // Same-machine: dial the relay's loopback address directly (no discovery needed).
    let relay_addr = server.local_dial_addr().await.unwrap();

    // Alice connects to the relay and PUTs the sealed blob.
    let alice_client = BlobClient::connect_addr(alice.node_secret_bytes(), relay_addr.clone())
        .await
        .unwrap();
    timeout(Duration::from_secs(10), alice_client.put(&key, &sealed))
        .await
        .expect("put timed out")
        .expect("put failed");

    // Prove the blob really landed on the relay's DISK as opaque ciphertext.
    let on_disk = std::fs::read(store_dir.join(&key)).expect("blob written to local disk");
    assert_eq!(on_disk, sealed, "the relay stored the exact sealed bytes, verbatim");
    assert_ne!(
        on_disk, plaintext,
        "what's on the relay's disk is ciphertext, not the plaintext media"
    );

    // Bob — a DIFFERENT node that never spoke to Alice — fetches the same key over iroh.
    let bob_client = BlobClient::connect_addr(bob.node_secret_bytes(), relay_addr.clone())
        .await
        .unwrap();
    assert!(
        timeout(Duration::from_secs(10), bob_client.has(&key))
            .await
            .expect("has timed out")
            .unwrap(),
        "relay reports it has the blob"
    );
    let fetched = timeout(Duration::from_secs(10), bob_client.get(&key))
        .await
        .expect("get timed out")
        .expect("get failed")
        .expect("relay returned the blob");
    assert_eq!(fetched, sealed, "Bob fetched the exact sealed bytes over Haven Net");

    // Bob opens it with HIS OWN circle keys → recovers Alice's original media.
    let env = SealedEnvelope::from_bytes(&fetched).unwrap();
    let opened = open_bytes(&bob, &alice.public(), &env).unwrap();
    assert_eq!(opened, plaintext, "Bob recovers Alice's exact media via the local-disk relay");

    // The relay is NOT a circle member, so even with the bytes it stored, it cannot
    // decrypt them. This is the non-key-holder guarantee, asserted directly.
    assert!(
        open_bytes(&relay_id, &alice.public(), &env).is_err(),
        "the relay must NOT be able to decrypt the blob it stored"
    );

    // LIST surfaces the key under the circle prefix (mailbox poll).
    let listed = timeout(Duration::from_secs(10), bob_client.list("mailbox/fam"))
        .await
        .expect("list timed out")
        .unwrap();
    assert!(listed.contains(&key), "the stored key shows up in a mailbox LIST");

    // A missing key is a clean MISS, not an error.
    let miss = bob_client.get("mailbox/fam/deadbeef").await.unwrap();
    assert!(miss.is_none(), "absent key returns None");

    alice_client.close().await;
    bob_client.close().await;
    let _ = std::fs::remove_dir_all(&store_dir);
    let _ = &server;
}

/// The **mailbox GC** proof, over the real wire: TOUCH refreshes an entry's liveness and
/// reports misses for repair, HAS hits refresh too, AGES exposes idle ages, and the TTL
/// sweep deletes exactly the entries no one re-asserted — never media, never fresh keys.
#[tokio::test]
async fn touch_refreshes_liveness_and_ttl_sweep_prunes_only_untouched_mailbox_entries() {
    use haven_net::blobstore::{gc_sweep, GC_GRACE, MAILBOX_TTL};

    let member = Identity::generate();
    let relay_id = Identity::generate();
    let store_dir = std::env::temp_dir().join(format!("haven-relay-gctest-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&store_dir);
    let server = BlobServer::spawn(relay_id.node_secret_bytes(), store_dir.clone()).await.unwrap();
    let relay_addr = server.local_dial_addr().await.unwrap();
    let client = BlobClient::connect_addr(member.node_secret_bytes(), relay_addr).await.unwrap();

    // One live entry, one legacy duplicate no client will ever re-assert, one media blob.
    let live = "haven/mailbox/fam/live".to_string();
    let dead = "haven/mailbox/fam/dead".to_string();
    let media = "haven/media/photo".to_string();
    for (k, v) in [(&live, b"sealed-live".as_slice()), (&dead, b"sealed-dead"), (&media, b"sealed-media")] {
        timeout(Duration::from_secs(10), client.put(k, v)).await.expect("put timed out").unwrap();
    }

    // Age everything past the TTL, as if the store predates GC / no one refreshed for a month.
    let ancient = std::time::SystemTime::now()
        - std::time::Duration::from_secs(MAILBOX_TTL.as_secs() + 24 * 3600);
    for k in [&live, &dead, &media] {
        std::fs::File::options()
            .write(true)
            .open(store_dir.join(k))
            .and_then(|f| f.set_modified(ancient))
            .unwrap();
    }

    // AGES reports the idle ages over the wire (the age-preserving mesh-sync inventory).
    let ages = timeout(Duration::from_secs(10), client.list_ages("haven/mailbox/fam/"))
        .await
        .expect("ages timed out")
        .unwrap();
    assert_eq!(ages.len(), 2);
    assert!(ages.iter().all(|(_, age)| *age > MAILBOX_TTL.as_secs()), "both entries look ancient");

    // The daily refresh: ONE batched TOUCH — the live key is re-asserted (clock resets), a
    // key the relay lost is reported back as a miss so the client re-PUTs it.
    let gone = "haven/mailbox/fam/gone".to_string();
    let misses = timeout(
        Duration::from_secs(10),
        client.touch("haven/mailbox/fam/", &[live.clone(), gone.clone()]),
    )
    .await
    .expect("touch timed out")
    .unwrap();
    assert_eq!(misses, vec![gone], "TOUCH reports exactly the keys the relay lacks");

    // A HAS hit also counts as liveness (the has-then-put upload path).
    std::fs::File::options()
        .write(true)
        .open(store_dir.join(&media))
        .and_then(|f| f.set_modified(ancient))
        .unwrap();
    assert!(timeout(Duration::from_secs(10), client.has(&media)).await.expect("has timed out").unwrap());

    // Sweep: plant the marker, age it past the first-enable grace, then sweep for real.
    assert_eq!(gc_sweep(&store_dir, MAILBOX_TTL, GC_GRACE), 0, "first call only plants the marker");
    std::fs::File::options()
        .write(true)
        .open(store_dir.join(".haven-gc-enabled"))
        .and_then(|f| f.set_modified(ancient))
        .unwrap();
    assert_eq!(gc_sweep(&store_dir, MAILBOX_TTL, GC_GRACE), 1, "exactly the dead entry is deleted");

    let listed = timeout(Duration::from_secs(10), client.list("haven/"))
        .await
        .expect("list timed out")
        .unwrap();
    assert!(listed.contains(&live), "the touched entry survives");
    assert!(listed.contains(&media), "media is never swept (HAS also re-stamped it)");
    assert!(!listed.contains(&dead), "the never-touched duplicate is gone");

    client.close().await;
    let _ = std::fs::remove_dir_all(&store_dir);
    let _ = &server;
}
