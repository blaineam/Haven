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

/// A relay a member TEACHES us for a circle becomes a sibling for THAT circle — it may replicate
/// that circle's mailbox from us (so two headless relays the same members use actually mesh,
/// which `--peer` flags used to be the only way to get) — and for nothing else: our other circles
/// stay out of its listings and out of its reach (found by the e2e `multirelay` step, where friends'
/// relays sharing one circle mirrored each other's private circles).
#[tokio::test]
async fn a_taught_sibling_replicates_that_circle_and_only_that_circle() {
    let alice = Identity::generate();
    let sibling = Identity::generate();
    let relay_id = Identity::generate();
    let dir = store_dir("sibling");
    let server = BlobServer::spawn(relay_id.node_secret_bytes(), dir.clone()).await.unwrap();
    let me = hex(&alice.public().node_id_bytes());
    server.authorize("shared", vec![me.clone()], vec![]);
    server.authorize("private", vec![me.clone()], vec![]);
    let addr = server.local_dial_addr().await.unwrap();
    let alice_c = BlobClient::connect_addr(alice.node_secret_bytes(), addr.clone()).await.unwrap();
    let shared_key = format!("haven/mailbox/shared/{}", "11".repeat(32));
    let private_key = format!("haven/mailbox/private/{}", "22".repeat(32));
    alice_c.put(&shared_key, b"s").await.unwrap();
    alice_c.put(&private_key, b"p").await.unwrap();

    let sib_hex = hex(&sibling.public().node_id_bytes());
    let sib_c = BlobClient::connect_addr(sibling.node_secret_bytes(), addr).await.unwrap();
    // Untaught: a stranger relay sees nothing.
    assert!(sib_c.list_ages("haven").await.map(|v| v.is_empty()).unwrap_or(true));

    timeout(Duration::from_secs(10), alice_c.enroll_relays("shared", &[sib_hex.clone()]))
        .await
        .expect("enroll_relays timed out")
        .expect("a member may teach the relay who else serves its circle");

    let listed: Vec<String> = sib_c.list_ages("haven").await.unwrap().into_iter().map(|(k, _)| k).collect();
    assert!(listed.contains(&shared_key), "the taught circle is replicated: {listed:?}");
    assert!(!listed.contains(&private_key), "another circle never appears in its listing: {listed:?}");
    assert_eq!(sib_c.get(&shared_key).await.unwrap().as_deref(), Some(&b"s"[..]));
    assert!(sib_c.get(&private_key).await.map(|b| b.is_none()).unwrap_or(true), "another circle is out of reach");
    // Persisted per circle, so a restart keeps the (scoped) relationship.
    let learned = haven_net::blobstore::load_learned_siblings(&dir);
    assert_eq!(learned, vec![("shared".to_string(), vec![sib_hex])]);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Removing a member revokes them on the relay (e2e `multirelay`): only the circle's CREATOR may
/// state a smaller member set, an ordinary member's stale view can't re-add the removed id, the
/// removal survives the link roster being re-applied, and the creator can bring them back.
#[tokio::test]
async fn the_creator_removing_a_member_revokes_them_on_the_relay() {
    let alice = Identity::generate(); // creator
    let bob = Identity::generate(); // removed
    let carol = Identity::generate(); // stays
    let relay_id = Identity::generate();
    let dir = store_dir("revoke");
    let server = BlobServer::spawn(relay_id.node_secret_bytes(), dir.clone()).await.unwrap();
    let (a, b, c) = (hex(&alice.public().node_id_bytes()), hex(&bob.public().node_id_bytes()), hex(&carol.public().node_id_bytes()));
    let circle = haven_p2p::device::mint_owned_circle_id(&alice.public().node_id_bytes());
    server.authorize(&circle, vec![a.clone(), b.clone(), c.clone()], vec![]);
    let addr = server.local_dial_addr().await.unwrap();
    let alice_c = BlobClient::connect_addr(alice.node_secret_bytes(), addr.clone()).await.unwrap();
    let bob_c = BlobClient::connect_addr(bob.node_secret_bytes(), addr.clone()).await.unwrap();
    let carol_c = BlobClient::connect_addr(carol.node_secret_bytes(), addr).await.unwrap();
    let prefix = format!("haven/mailbox/{circle}/");
    assert!(bob_c.list(&prefix).await.is_ok(), "bob is a member to begin with");
    // Bob also HOSTS a relay for the circle, in-app — whose relay id is his own device id, so he is
    // a sibling for it too. The removal has to close that door as well.
    alice_c.enroll_relays(&circle, &[b.clone()]).await.expect("a member may name the circle's relays");

    // Not the creator: refused, nothing changes.
    assert!(carol_c.enroll_replace(&circle, &[c.clone(), a.clone()]).await.is_err());
    assert!(bob_c.list(&prefix).await.is_ok());

    // The creator removes bob.
    alice_c.enroll_replace(&circle, &[a.clone(), c.clone()]).await.expect("the creator may state the member set");
    assert!(bob_c.list(&prefix).await.is_err(), "a removed member can no longer list the circle");
    assert!(
        bob_c.list_ages("haven").await.map(|v| v.iter().all(|(k, _)| !k.starts_with(&prefix))).unwrap_or(true),
        "nor see it through a sibling listing"
    );
    // Re-teaching him as the circle's relay doesn't reopen it either.
    carol_c.enroll_relays(&circle, &[b.clone()]).await.ok();
    assert!(bob_c.list(&prefix).await.is_err(), "a removed member's relay is not the circle's relay");
    assert!(carol_c.list(&prefix).await.is_ok(), "the others keep their access");

    // A member with a stale view (still listing bob) cannot re-add him.
    carol_c.enroll(&circle, &[c.clone(), b.clone()]).await.expect("carol's enroll is accepted for herself");
    assert!(bob_c.list(&prefix).await.is_err(), "a stale enroll must not undo the creator's removal");

    // The link's roster re-applied (what every restart does) doesn't bring him back either.
    server.authorize(&circle, vec![a.clone(), b.clone(), c.clone()], vec![]);
    assert!(bob_c.list(&prefix).await.is_err(), "re-applying a roster that names him must not undo it");
    let revoked = haven_net::blobstore::load_learned_revocations(&dir);
    assert!(revoked.iter().any(|(cc, x)| cc == &circle && x.contains(&b)), "revocation persisted: {revoked:?}");

    // The creator re-adding him does.
    alice_c.enroll(&circle, &[a.clone(), b.clone()]).await.unwrap();
    assert!(bob_c.list(&prefix).await.is_ok(), "the creator can re-add a removed member");
    let _ = std::fs::remove_dir_all(&dir);
}
