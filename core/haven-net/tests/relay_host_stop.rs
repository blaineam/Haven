//! "Stop hosting" must actually stop.
//!
//! Found by the e2e `multirelay` step (B toggles its in-app relay off and on while friends keep
//! using it): after the toggle the Mac host was still LISTENING on its old media port (8674) and
//! its old path proxy (8675), still answering requests on connections opened before the stop, and
//! — because the old port was never released — came back on a random port, so every member had to
//! re-learn a URL while the "stopped" relay kept serving the old one.
//!
//! Three leaks, one test each: a dropped `PathRouter` detached its task instead of stopping it
//! (dropping a tokio `JoinHandle` does not abort), the HTTP interface's per-connection tasks
//! outlived the interface, and the port must be re-bindable once the relay is disabled.

use std::io::{Read, Write};
use std::time::Duration;

use haven_net::blobstore::BlobClient;
use haven_net::{PathRouter, PathRouterConfig, RelayNode};
use haven_p2p::identity::Identity;

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

/// Is anything still accepting on `port`? (A refused connect = nobody.)
fn accepting(port: u16) -> bool {
    std::net::TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), Duration::from_millis(300)).is_ok()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn disabling_the_relay_releases_its_http_port_and_connections() {
    let dir = std::env::temp_dir().join(format!("haven-host-stop-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let relay = RelayNode::spawn([42u8; 32], None).await.unwrap();
    let node = relay.node();
    node.enable_relay(dir.clone());
    let port = free_port();
    assert_eq!(node.relay_serve_http(&format!("127.0.0.1:{port}"), "tok").await.unwrap(), port);

    // A client with a keep-alive connection open across the stop (every member's poller has one).
    let mut idle = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    idle.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;

    node.disable_relay();
    tokio::time::sleep(Duration::from_millis(300)).await;

    assert!(!accepting(port), "the stopped relay is still accepting connections on :{port}");
    // The connection opened before the stop must not be served by a relay that was turned off.
    // Closed (Ok(0)) or reset is right; an ANSWER means the relay is still serving after the stop.
    let _ = idle.write_all(b"GET /k/haven/media/x HTTP/1.1\r\nHost: x\r\n\r\n");
    let mut buf = [0u8; 64];
    match idle.read(&mut buf) {
        Ok(n) if n > 0 => panic!("a pre-stop connection was still answered: {:?}", String::from_utf8_lossy(&buf[..n])),
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::ConnectionReset => {}
        Err(e) => panic!("a pre-stop connection is still held open by the stopped relay ({e})"),
    }

    // Hosting again binds the SAME port (the toggle must not move the relay's URL).
    node.enable_relay(dir.clone());
    assert_eq!(node.relay_serve_http(&format!("127.0.0.1:{port}"), "tok").await.unwrap(), port);
    node.disable_relay();
    let _ = std::fs::remove_dir_all(&dir);
}

/// The Mac host kept answering on :8674 after "stop hosting" — in every e2e run, never in a unit
/// test — until the next fabric rebind restarted the messaging node. The difference: in the fleet,
/// members hold warm iroh blob-ALPN connections to the host, and the node's accept loop cloned the
/// WHOLE relay config (HTTP interface included) into each such connection for its lifetime, so
/// `disable_relay` dropped only one of several owners of the HTTP listener. The listener has to
/// die with the relay no matter who is connected over iroh — and so must the iroh connections'
/// access to the store.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_open_iroh_blob_connection_does_not_keep_a_stopped_relay_serving() {
    let dir = std::env::temp_dir().join(format!("haven-host-stop-iroh-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let relay = RelayNode::spawn([43u8; 32], None).await.unwrap();
    let node = relay.node();
    node.enable_relay(dir.clone());
    let member = Identity::generate();
    let member_hex: String = member.public().node_id_bytes().iter().map(|b| format!("{b:02x}")).collect();
    node.relay_authorize("fam", vec![member_hex], vec![]);
    let port = free_port();
    assert_eq!(node.relay_serve_http(&format!("127.0.0.1:{port}"), "tok").await.unwrap(), port);

    // A member's warm blob connection, opened (and used) while hosting.
    let client = BlobClient::connect_addr(member.node_secret_bytes(), relay.local_dial_addr().await.unwrap())
        .await
        .unwrap();
    let key = format!("haven/mailbox/fam/{}", "22".repeat(32));
    tokio::time::timeout(Duration::from_secs(10), client.put(&key, b"sealed"))
        .await
        .expect("put timed out")
        .expect("a member may write while the relay is hosted");

    node.disable_relay();
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while accepting(port) && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(!accepting(port), "a stopped relay still accepts on :{port} while a member holds an iroh blob connection");
    // …and that connection may not keep reading the store of a relay that was turned off.
    let got = tokio::time::timeout(Duration::from_secs(10), client.get(&key)).await;
    assert!(
        !matches!(got, Ok(Ok(Some(_)))),
        "a stopped relay still served a blob over a pre-stop iroh connection"
    );
    drop(client);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropping_the_path_router_stops_it() {
    let port = free_port();
    let router = PathRouter::spawn(&PathRouterConfig {
        bind: format!("127.0.0.1:{port}"),
        media_backend: "127.0.0.1:9".into(),
        derp_backend: String::new(),
        http_token: String::new(),
    })
    .await
    .unwrap()
    .expect("router");
    assert!(accepting(port));
    drop(router);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!accepting(port), "a dropped path router is still accepting on :{port}");
}
