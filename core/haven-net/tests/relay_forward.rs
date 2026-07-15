//! The connection-relay proof: Alice's sealed post reaches Bob **through a relay**,
//! and the relay never opens the payload.
//!
//! Topology: Alice and Bob never exchange a direct address. Alice dials only the
//! **relay**, hands it a mesh-relay frame addressed to Bob, and the relay forwards the
//! opaque payload to Bob. Bob opens it with his own keys — proving the relay moved
//! ciphertext it could not read, between two peers that weren't directly wired up.

use std::sync::Arc;

use haven_net::relay::RoutingFrame;
use haven_net::{Node, RelayNode};
use p2pcore::identity::Identity;
use p2pcore::social::{open_event, seal_event, Event, EventKind, Group, SealedEnvelope};
use tokio::time::{timeout, Duration};

#[tokio::test]
async fn relay_forwards_sealed_post_between_indirect_peers() {
    let alice = Identity::generate();
    let bob = Identity::generate();
    let relay_id = Identity::generate();
    let group = Group::new("fam", vec![alice.public(), bob.public()]);

    // Alice seals a post to the circle (relay is NOT a member, holds no key).
    let event = Event::new(
        &alice.public().node_id_bytes(),
        7,
        EventKind::Post {
            body: "routed through a relay 🛰️".into(),
            media: vec![],
            music: None,
            retention_secs: None,
            story: false,
            mute_video: false,
        },
    );
    let payload = seal_event(&alice, &group, &event).unwrap().to_bytes();

    // Bob listens. The relay must be able to forward to him, so Bob dials the relay
    // first (establishing a reusable connection the relay can send back on) — exactly
    // how an offline-friendly member registers with its circle's relay.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let bob_node = Node::spawn(bob.node_secret_bytes(), Arc::new(move |_from: [u8; 32], p: Vec<u8>| {
        // A member peels the relay header (if present) before opening.
        let inner = RoutingFrame::parse(&p).map(|f| f.payload).unwrap_or(p);
        let _ = tx.send(inner);
    }))
    .await
    .unwrap();

    // Pure-forwarder relay: no member handler, it can't read anything.
    let relay = RelayNode::spawn(relay_id.node_secret_bytes(), None).await.unwrap();
    let relay_hex = relay.node_id_hex();

    // Bob connects to the relay so the relay holds a live connection to dial back on.
    let relay_addr = relay.local_dial_addr().await.unwrap();
    bob_node.send(relay_addr, b"register").await.unwrap();
    // Give the relay a moment to accept Bob's connection.
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Alice dials ONLY the relay and asks it to forward to Bob. Alice never learns
    // Bob's address; Bob never learned Alice's. The relay bridges them.
    let alice_node = Node::spawn(alice.node_secret_bytes(), Arc::new(|_: [u8; 32], _: Vec<u8>| {})).await.unwrap();
    let relay_dial = relay.local_dial_addr().await.unwrap();
    // Establish Alice→relay via loopback, then forward by relay's node id.
    alice_node.send(relay_dial, b"hello-relay").await.unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    alice_node
        .send_via_relay(&relay_hex, vec![bob.public().node_id_bytes()], &payload)
        .await
        .unwrap();

    // Bob receives the forwarded opaque bytes and opens the post with HIS keys.
    let received = timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("relay forward timed out")
        .expect("channel closed");
    let env = SealedEnvelope::from_bytes(&received).unwrap();
    let opened = open_event(&bob, &alice.public(), &env).unwrap();

    assert_eq!(opened, event, "Bob recovers Alice's exact post, forwarded by the relay");

    // Sanity: the relay's identity is NOT a recipient of the envelope, so even if it
    // tried, it could not open the payload.
    assert!(
        open_event(&relay_id, &alice.public(), &env).is_err(),
        "the relay must not be able to open the forwarded envelope"
    );

    alice_node.close().await;
    bob_node.close().await;
}

/// Audit F10: a relay is a switchboard for ITS circle, not an open reflector. A stranger who
/// learns the relay's node id must not be able to aim its bandwidth at third parties of their
/// choosing — while the circle's own traffic keeps flowing.
#[tokio::test]
async fn relay_refuses_to_forward_between_two_strangers() {
    let member = Identity::generate();
    let attacker = Identity::generate();
    let victim = Identity::generate(); // an arbitrary third party the attacker picks
    let relay_id = Identity::generate();

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let victim_node = Node::spawn(victim.node_secret_bytes(), Arc::new(move |_: [u8; 32], p: Vec<u8>| {
        let _ = tx.send(RoutingFrame::parse(&p).map(|f| f.payload).unwrap_or(p));
    }))
    .await
    .unwrap();

    let relay = RelayNode::spawn(relay_id.node_secret_bytes(), None).await.unwrap();
    relay.authorize_forwarding(vec![hex(&member.public().node_id_bytes())]);
    let relay_hex = relay.node_id_hex();

    // The victim is reachable from the relay (a live connection to reflect onto).
    let relay_addr = relay.local_dial_addr().await.unwrap();
    victim_node.send(relay_addr, b"register").await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;

    // The attacker asks the relay to fling bytes at the victim. Neither of them is a member.
    let attacker_node = Node::spawn(attacker.node_secret_bytes(), Arc::new(|_: [u8; 32], _: Vec<u8>| {})).await.unwrap();
    let relay_dial = relay.local_dial_addr().await.unwrap();
    attacker_node.send(relay_dial, b"hello-relay").await.unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    attacker_node
        .send_via_relay(&relay_hex, vec![victim.public().node_id_bytes()], b"AMPLIFY-ME")
        .await
        .unwrap();

    assert!(
        timeout(Duration::from_secs(3), rx.recv()).await.is_err(),
        "the relay reflected a stranger's frame at a third party"
    );

    // The circle's own traffic is untouched: a frame TOWARD a member still forwards.
    let (mtx, mut mrx) = tokio::sync::mpsc::unbounded_channel();
    let member_node = Node::spawn(member.node_secret_bytes(), Arc::new(move |_: [u8; 32], p: Vec<u8>| {
        let _ = mtx.send(RoutingFrame::parse(&p).map(|f| f.payload).unwrap_or(p));
    }))
    .await
    .unwrap();
    member_node.send(relay.local_dial_addr().await.unwrap(), b"register").await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    attacker_node
        .send_via_relay(&relay_hex, vec![member.public().node_id_bytes()], b"FOR-A-MEMBER")
        .await
        .unwrap();
    let got = timeout(Duration::from_secs(10), mrx.recv()).await.expect("member delivery timed out");
    assert_eq!(got.as_deref(), Some(&b"FOR-A-MEMBER"[..]), "a frame toward a member still forwards");

    attacker_node.close().await;
    victim_node.close().await;
    member_node.close().await;
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
