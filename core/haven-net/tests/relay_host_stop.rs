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

use haven_net::{PathRouter, PathRouterConfig, RelayNode};

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
