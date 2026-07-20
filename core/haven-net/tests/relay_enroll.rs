//! The relay link is a **pairing handshake**, not a frozen policy — proved end to end over iroh.
//!
//! ## The incident this test exists for
//!
//! A user's NAS relay printed `authorized 1 circle(s) from the link` and then refused every circle
//! except that one, forever. It refused every `dm:` circle in particular — DM circles are minted on
//! demand the first time two people message, so they can never be in a link that was pasted before
//! the conversation existed. The consequence was that DMs had **no store-and-forward at all**: a
//! message only arrived if both devices happened to be online at the same moment, which the user
//! experienced as "received DMs only show up on one of my devices". Re-pasting a link fixed it until
//! the next restart re-applied the stale one from the Docker `.env`.
//!
//! Three proofs, in the order they matter:
//!
//! 1. `a_paired_member_teaches_the_relay_a_circle_it_was_never_linked_for` — a member the relay
//!    already serves PUTs into a brand-new circle. The relay refuses, the client enrolls, the retry
//!    lands. No re-pasting, no restart.
//! 2. `an_unpaired_stranger_cannot_enroll_anything` — the same sequence from a node the relay has
//!    never served gets nothing. This is the check that stops every relay on the internet from
//!    becoming free storage for anyone who learns its node id.
//! 3. `a_member_cannot_enroll_itself_into_someone_elses_circle` — being paired is permission to
//!    teach the relay about YOUR circles, not to join anybody else's.

use haven_net::blobstore::{BlobClient, BlobServer};
use haven_p2p::identity::Identity;
use tokio::time::{timeout, Duration};

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn store_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("haven-enroll-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[tokio::test]
async fn a_paired_member_teaches_the_relay_a_circle_it_was_never_linked_for() {
    let alice = Identity::generate();
    let relay_id = Identity::generate();
    let dir = store_dir("teach");

    let server = BlobServer::spawn(relay_id.node_secret_bytes(), dir.clone()).await.unwrap();
    // Exactly the shipped headless case: ONE circle, from the operator's pasted link.
    server.authorize("default", vec![hex(&alice.public().node_id_bytes())], vec![]);
    let addr = server.local_dial_addr().await.unwrap();

    let client = BlobClient::connect_addr(alice.node_secret_bytes(), addr).await.unwrap();

    // A circle created long after the link was pasted. Before ENROLL this PUT was `ERR forbidden`
    // and stayed that way for the life of the relay — the client had no way to say "this is mine
    // too" and the operator's only recourse was to paste a fresh link (which the next container
    // restart then reverted).
    let circle = "c1madeAfterTheLink";
    let key = format!("haven/mailbox/{circle}/{}", "11".repeat(32));
    timeout(Duration::from_secs(10), client.put(&key, b"sealed-envelope"))
        .await
        .expect("put timed out")
        .expect("a paired member must be able to teach the relay a new circle and then use it");

    // It really landed on the relay's disk — not merely "no error".
    let on_disk =
        std::fs::read(dir.join("haven").join("mailbox").join(circle).join("11".repeat(32)))
            .expect("the sealed envelope is stored");
    assert_eq!(on_disk, b"sealed-envelope");

    // The DM case, which is the one the user actually hit. A `dm:` circle is minted the first time
    // two people message, so it can never appear in a link pasted beforehand. Alice enrolls it with
    // BOTH participants, so the relay will store-and-forward for her correspondent too — that is the
    // store-and-forward that was missing when "received DMs only show up on one of my devices".
    let me = hex(&alice.public().node_id_bytes());
    let dm = format!("dm:{}-{}", &me[..8], "beefcafe");
    timeout(Duration::from_secs(10), client.enroll(&dm, &[me.clone(), "77".repeat(32)]))
        .await
        .expect("enroll timed out")
        .expect("a paired member may enroll a DM circle it belongs to");

    // Both SURVIVE A RESTART. The persisted grant is what makes the Docker footgun harmless:
    // re-applying the same stale link on every container start no longer un-learns anything.
    let learned = haven_net::blobstore::load_learned_grants(&dir);
    assert!(
        learned.iter().any(|(c, m)| c == circle && m.contains(&me)),
        "the learned circle is persisted in the relay data dir, not just held in memory: {learned:?}"
    );
    let dm_grant = learned.iter().find(|(c, _)| c == &dm).expect("the DM circle persisted too");
    assert!(dm_grant.1.contains(&"77".repeat(32)), "the correspondent is served as well");

    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn an_unpaired_stranger_cannot_enroll_anything() {
    let alice = Identity::generate();
    let mallory = Identity::generate();
    let relay_id = Identity::generate();
    let dir = store_dir("stranger");

    let server = BlobServer::spawn(relay_id.node_secret_bytes(), dir.clone()).await.unwrap();
    server.authorize("default", vec![hex(&alice.public().node_id_bytes())], vec![]);
    let addr = server.local_dial_addr().await.unwrap();

    // Mallory knows the relay's node id — that is public routing data, so assume she does.
    let client = BlobClient::connect_addr(mallory.node_secret_bytes(), addr).await.unwrap();

    // The direct attempt: enroll a circle of her own.
    let me = hex(&mallory.public().node_id_bytes());
    let err = timeout(Duration::from_secs(10), client.enroll("mallorys-warez", &[me.clone()]))
        .await
        .expect("enroll timed out");
    assert!(err.is_err(), "an unpaired caller must not be able to enroll a circle");

    // The indirect attempt: PUT into a new circle and let the auto-enroll recovery try for her.
    let key = format!("haven/mailbox/mallorys-warez/{}", "22".repeat(32));
    let put = timeout(Duration::from_secs(10), client.put(&key, b"free storage please"))
        .await
        .expect("put timed out");
    assert!(put.is_err(), "the recovery path must not hand a stranger the circle either");

    assert!(
        haven_net::blobstore::load_learned_grants(&dir).is_empty(),
        "a refused enroll must leave nothing on disk for a restart to honour"
    );
    assert!(!dir.join("haven").join("mailbox").join("mallorys-warez").exists());

    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_member_cannot_enroll_itself_into_someone_elses_circle() {
    let alice = Identity::generate();
    let mallory = Identity::generate();
    let relay_id = Identity::generate();
    let dir = store_dir("escalate");

    let server = BlobServer::spawn(relay_id.node_secret_bytes(), dir.clone()).await.unwrap();
    // Both are legitimate users of this relay, in DIFFERENT circles. That is what makes Mallory the
    // interesting attacker here: she is paired, so the front-door check does not stop her.
    server.authorize("alices-family", vec![hex(&alice.public().node_id_bytes())], vec![]);
    server.authorize("mallorys-circle", vec![hex(&mallory.public().node_id_bytes())], vec![]);
    let addr = server.local_dial_addr().await.unwrap();

    let client = BlobClient::connect_addr(mallory.node_secret_bytes(), addr).await.unwrap();
    let me = hex(&mallory.public().node_id_bytes());
    let res = timeout(Duration::from_secs(10), client.enroll("alices-family", &[me]))
        .await
        .expect("enroll timed out");
    assert!(res.is_err(), "a circle may only be extended from the inside");

    // …and she still cannot read it.
    let key = format!("haven/mailbox/alices-family/{}", "33".repeat(32));
    let put =
        timeout(Duration::from_secs(10), client.put(&key, b"hello")).await.expect("put timed out");
    assert!(put.is_err(), "the escalation guard holds on the storage path too");

    let _ = std::fs::remove_dir_all(&dir);
}
