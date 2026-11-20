//! The entry point the Mac and Android relay hosts use to serve the web client
//! (`PathRouterHandle::spawn_with_web_app`): it serves the build under `/app/`, reports the same
//! digest `web_app_digest` shows the user, and REFUSES a directory that is not a web client build —
//! a host that asked for web access must never end up quietly serving something else, or nothing.

use std::io::{Read, Write};

use haven_ffi::{web_app_digest, PathRouterHandle};

fn dist(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("haven-ffi-webapp-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("pkg")).unwrap();
    d
}

fn get(port: u16, path: &str) -> String {
    let mut s = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.set_read_timeout(Some(std::time::Duration::from_secs(10))).unwrap();
    write!(s, "GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").unwrap();
    let mut out = Vec::new();
    let _ = s.read_to_end(&mut out);
    String::from_utf8_lossy(&out).into_owned()
}

fn rt() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap()
}

#[test]
fn a_host_that_turns_web_access_on_serves_the_build_it_was_shown() {
    let d = dist("ok");
    std::fs::write(d.join("index.html"), "<!doctype html><title>Haven</title>").unwrap();
    std::fs::write(d.join("pkg/haven_web_bg.wasm"), [0u8, 97, 115, 109]).unwrap();
    let digest = web_app_digest(d.to_string_lossy().into_owned()).expect("a build has a digest");
    assert!(!digest.is_empty());

    let rt = rt();
    let router = rt
        .block_on(PathRouterHandle::spawn_with_web_app(
            "127.0.0.1:0".into(),
            "127.0.0.1:1".into(),
            "127.0.0.1:1".into(),
            String::new(),
            d.to_string_lossy().into_owned(),
        ))
        .expect("spawns with a web client");
    let port = router.local_port();

    let (index, status) = rt.block_on(async {
        tokio::task::spawn_blocking(move || (get(port, "/app/"), get(port, "/_haven"))).await.unwrap()
    });
    assert!(index.starts_with("HTTP/1.1 200"), "{index}");
    assert!(index.contains("<title>Haven</title>"), "{index}");
    assert!(index.to_ascii_lowercase().contains("content-security-policy"), "{index}");
    assert!(status.contains(&digest), "status reports the digest the host showed: {status}");
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn a_directory_that_is_not_a_web_client_build_is_refused() {
    // No index.html.
    let empty = dist("empty");
    assert!(web_app_digest(empty.to_string_lossy().into_owned()).is_err());

    // A file a web client build never contains.
    let odd = dist("odd");
    std::fs::write(odd.join("index.html"), "<!doctype html>").unwrap();
    std::fs::write(odd.join("secrets.env"), "x=1").unwrap();
    assert!(web_app_digest(odd.to_string_lossy().into_owned()).is_err());

    let rt = rt();
    for d in [&empty, &odd] {
        let r = rt.block_on(PathRouterHandle::spawn_with_web_app(
            "127.0.0.1:0".into(),
            "127.0.0.1:1".into(),
            "127.0.0.1:1".into(),
            String::new(),
            d.to_string_lossy().into_owned(),
        ));
        assert!(r.is_err(), "must fail, not serve without the web client");
        let _ = std::fs::remove_dir_all(d);
    }
}
