//! A burst of concurrent sends to one unreachable peer must produce ONE in-flight dial,
//! not one per sender. The per-peer dial gate alone can't stop the burst — it's checked
//! before `endpoint.connect` and only updated when a dial finishes (~30s for a dead id),
//! so every send queued in that window used to open its own doomed `Connecting`, each one
//! churning iroh's path actor (`open_path_on_all_conns`) — the tens-of-GB build-174 leak.

use std::sync::Arc;

use haven_net::Node;
use haven_p2p::identity::Identity;
use tokio::time::{sleep, Duration};

#[tokio::test]
async fn concurrent_sends_to_a_dead_peer_share_one_dial() {
    let me = Identity::generate();
    let node = Arc::new(Node::spawn(me.node_secret_bytes(), Arc::new(|_: [u8; 32], _: Vec<u8>| {})).await.unwrap());

    // A valid-format node id nobody runs (fresh identity, never bound) — every dial to it
    // hangs in discovery/handshake until iroh's timeout, exactly like an offline device.
    let dead = Identity::generate();
    let dead_hex = hex32(&dead.public().node_id_bytes());

    // The build-174 pattern: a sync cycle fanning out a burst of sends to the same id.
    let mut tasks = Vec::new();
    for _ in 0..20 {
        let n = node.clone();
        let d = dead_hex.clone();
        tasks.push(tokio::spawn(async move {
            let _ = n.send_to_node(&d, b"ping").await;
        }));
    }

    // Well inside the winner's dial timeout: every sender has either queued on the
    // single-flight lock or bailed on the gate — none may have started its own dial.
    sleep(Duration::from_secs(3)).await;
    assert_eq!(
        node.dial_attempt_count(),
        1,
        "a concurrent send burst to one dead id must collapse to a single dial"
    );

    for t in tasks {
        t.abort();
    }
}

fn hex32(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
