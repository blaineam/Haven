//! Two nodes exchange a real sealed social post over QUIC — the networking proof
//! that turns "waiting to connect" into an actual connection.

use std::sync::Arc;

use haven_net::Node;
use p2pcore::identity::Identity;
use p2pcore::social::{open_event, seal_event, Event, EventKind, Group, SealedEnvelope};
use tokio::time::{timeout, Duration};

#[tokio::test]
async fn two_nodes_exchange_a_sealed_post() {
    let alice = Identity::generate();
    let bob = Identity::generate();
    let group = Group::new("fam", vec![alice.public(), bob.public()]);

    // Alice composes and seals a post to the group.
    let event = Event::new(
        &alice.public().node_id_bytes(),
        42,
        EventKind::Post { body: "hello from across the network 🌍".into(), media: vec![], music: None, retention_secs: None, story: false, mute_video: false },
    );
    let payload = seal_event(&alice, &group, &event).unwrap().to_bytes();

    // Bob listens (inbound payloads go to a channel); Alice dials Bob and sends.
    // Each node binds to its identity's key, so its transport id == its Haven id.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let bob_node = Node::spawn(bob.node_secret_bytes(), Arc::new(move |from: [u8; 32], p: Vec<u8>| {
        let _ = tx.send((from, p));
    }))
    .await
    .unwrap();
    assert_eq!(bob_node.node_id_hex(), hex32(&bob.public().node_id_bytes()),
               "transport node id must equal the Haven identity id");
    let bob_addr = bob_node.local_dial_addr().await.unwrap();
    let alice_node = Node::spawn(alice.node_secret_bytes(), Arc::new(|_: [u8; 32], _: Vec<u8>| {})).await.unwrap();
    alice_node.send(bob_addr, &payload).await.unwrap();

    // Bob receives the opaque bytes and opens the post with his own keys.
    let (from, received) = timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("recv timed out")
        .expect("channel closed");
    // A direct frame carries the sender's AUTHENTICATED transport id (the reply-path bootstrap).
    assert_eq!(hex32(&from), alice_node.node_id_hex(),
               "direct delivery must surface the sender's authenticated node id");
    let env = SealedEnvelope::from_bytes(&received).unwrap();
    let opened = open_event(&bob, &alice.public(), &env).unwrap();

    assert_eq!(opened, event, "Bob recovers Alice's exact post over the network");

    alice_node.close().await;
    bob_node.close().await;
}

fn hex32(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
