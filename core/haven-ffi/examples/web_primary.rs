//! Native counterpart for the browser-session smoke (`web-client/smoke`): an account's PRIMARY
//! device — the real engine on a real Haven node — plus a circle DERP, so a tab can be linked as a
//! seedless device and exchange sealed circle events with it over the app wire.
//!
//! ```sh
//! cargo run -p haven_ffi --example web_primary -- 127.0.0.1:0
//! ```
//!
//! Prints `DERP=<url>`, `NODE=<device hex>`, `ACCOUNT=<hex>` and `TICKET=<haven-enroll:…>`. It then
//! plays the primary's half of the protocol exactly as the apps do (frames 28/29/1), auto-approving
//! the one ticket it minted:
//!
//! * frame 28 that verifies under the ticket → register the device, answer with frame 29, print
//!   `ENROLLED <device hex>`, then post "hello from the primary" and hand over its sync bundle;
//! * with a second argument `tamper`, the frame-29 answer has one byte flipped and nothing follows
//!   (`TAMPERED-GRANT-SENT <device hex>`) — the negative case;
//! * frame 1 → `receive`, then print the feed as `FEED <me|other> <body>` lines and `FEED-END`.

use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use haven_ffi::{enroll, HavenSocial};
use haven_net::{set_endpoint_policy, DerpConfig, DerpServer, EndpointPolicy, InboundHandler, Node};
use haven_p2p::identity::Identity;

const CIRCLE: &str = "default";
const EVENT: u8 = 1;
const SEEDLESS_ENROLL_REQ: u8 = 28;
const SEEDLESS_ENROLL_GRANT: u8 = 29;

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn event_frame(circle: &str, envelope: &[u8]) -> Vec<u8> {
    let mut out = vec![EVENT];
    out.extend_from_slice(&(circle.len() as u16).to_le_bytes());
    out.extend_from_slice(circle.as_bytes());
    out.extend_from_slice(envelope);
    out
}

fn parse_event(payload: &[u8]) -> Option<(String, Vec<u8>)> {
    let len = u16::from_le_bytes([*payload.first()?, *payload.get(1)?]) as usize;
    let id = String::from_utf8(payload.get(2..2 + len)?.to_vec()).ok()?;
    Some((id, payload[2 + len..].to_vec()))
}

type AnyResult<T> = Result<T, Box<dyn std::error::Error>>;

fn main() -> AnyResult<()> {
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
    rt.block_on(run())
}

async fn run() -> AnyResult<()> {
    let bind = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:0".into());
    // `tamper`: answer the request with a grant that has one byte flipped, and nothing else — the
    // requesting device must refuse it and stay unlinked.
    let tamper = std::env::args().nth(2).as_deref() == Some("tamper");
    let derp = DerpServer::spawn(&DerpConfig { enabled: true, bind: bind.clone(), public_url: format!("http://{bind}") })
        .await?
        .expect("derp enabled");
    let url = format!("http://{}", derp.local_addr);
    println!("DERP={url}");
    set_endpoint_policy(EndpointPolicy::haven_only([url]));

    // A throwaway account for this run (the OS CSPRNG; this harness is unix-only).
    let mut seed = [0u8; 32];
    std::io::Read::read_exact(&mut std::fs::File::open("/dev/urandom")?, &mut seed)?;
    let account = Identity::from_seed(&seed);
    let social = HavenSocial::new(seed.to_vec()).map_err(|e| e.to_string())?;
    let primary_device = account.public().node_id_bytes().to_vec();
    let ticket = enroll::enroll_issue_ticket(social.my_bundle(), primary_device, now_secs(), vec![])
        .map_err(|e| e.to_string())?;
    let secret = ticket.secret.clone();
    let used = Arc::new(Mutex::new(false));

    let slot: Arc<OnceLock<Arc<Node>>> = Arc::new(OnceLock::new());
    let handle = tokio::runtime::Handle::current();
    let handler: InboundHandler = {
        let (slot, social, used) = (slot.clone(), social.clone(), used.clone());
        Arc::new(move |from: [u8; 32], frame: Vec<u8>| {
            let Some(node) = slot.get().cloned() else { return };
            let Some((&kind, body)) = frame.split_first() else { return };
            let from_hex = hex(&from);
            match kind {
                SEEDLESS_ENROLL_REQ => {
                    let now = now_secs();
                    let Ok(req) = enroll::enroll_verify_request(secret.clone(), body.to_vec(), now, 600) else {
                        println!("ENROLL-REJECTED {from_hex}");
                        return;
                    };
                    {
                        let mut used = used.lock().unwrap();
                        if *used {
                            return; // single-use ticket
                        }
                        *used = true;
                    }
                    // Union the device into the account's signed roster, then grant: credential +
                    // that roster verbatim + the sealed self-sync key, all MAC'd under the ticket.
                    let roster_wire = social.register_device(req.device_bundle.clone(), req.name.clone(), now);
                    let grant = enroll::enroll_assemble_grant(
                        seed.to_vec(), secret.clone(), req.device_bundle, req.name, now, roster_wire, vec![],
                    )
                    .expect("assemble grant");
                    let mut frame29 = vec![SEEDLESS_ENROLL_GRANT];
                    frame29.extend_from_slice(&grant);
                    if tamper {
                        let last = frame29.len() - 1;
                        frame29[last] ^= 0x01;
                        handle.spawn(async move {
                            let _ = node.send_to_node(&from_hex, &frame29).await;
                            println!("TAMPERED-GRANT-SENT {from_hex}");
                        });
                        return;
                    }
                    let social = social.clone();
                    handle.spawn(async move {
                        if let Err(e) = node.send_to_node(&from_hex, &frame29).await {
                            println!("GRANT-FAILED {e}");
                            return;
                        }
                        println!("ENROLLED {from_hex}");
                        let now_ms = now_secs() * 1000;
                        social
                            .post(CIRCLE.into(), "hello from the primary".into(), vec![], None, None, false, false, now_ms)
                            .expect("primary posts");
                        for env in social.sync_envelopes(CIRCLE.into()) {
                            if let Err(e) = node.send_to_node(&from_hex, &event_frame(CIRCLE, &env)).await {
                                println!("SEND-FAILED {e}");
                            }
                        }
                        println!("SENT");
                    });
                }
                EVENT => {
                    let Some((circle, envelope)) = parse_event(body) else { return };
                    match social.receive(circle.clone(), envelope) {
                        Ok(true) => {
                            for item in social.feed(circle, now_secs() * 1000, None) {
                                println!("FEED {} {}", if item.is_me { "me" } else { "other" }, item.body);
                            }
                            println!("FEED-END");
                        }
                        Ok(false) => {}
                        Err(e) => println!("RECEIVE-FAILED {e}"),
                    }
                }
                _ => {}
            }
        })
    };
    let node = Arc::new(Node::spawn(account.node_secret_bytes(), handler).await.map_err(|e| e.to_string())?);
    let _ = slot.set(node.clone());
    println!("NODE={}", node.node_id_hex());
    println!("ACCOUNT={}", social.my_node_hex());
    println!("TICKET={}", enroll::enroll_ticket_encode(ticket).map_err(|e| e.to_string())?);
    std::future::pending::<()>().await;
    Ok(())
}
