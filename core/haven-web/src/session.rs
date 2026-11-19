//! A linked Haven device living in a tab: the engine ([`HavenSocial`], seedless) driven over a
//! [`WebNode`].
//!
//! This is the start of the browser's client layer — what `desktop/src-tauri/src/engine.rs` is for
//! the desktop app. It currently covers enrollment and live circle events; mailbox sync, storage,
//! media and calls build on the same shape.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use futures_channel::oneshot;
use haven_ffi::enroll::{self, EnrollTicketFfi};
use haven_ffi::HavenSocial;
use haven_p2p::identity::Identity;
use wasm_bindgen::prelude::*;

use haven_client::wire;

use crate::{err, hex, now_secs, secret32, WebNode};

fn now_ms() -> u64 {
    web_time::SystemTime::now().duration_since(web_time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

struct Linking {
    ticket: EnrollTicketFfi,
    done: oneshot::Sender<Result<(), String>>,
}

struct Inner {
    device_seed: [u8; 32],
    /// `None` until a grant has been accepted — an unlinked tab holds a device key and nothing else.
    social: Option<Arc<HavenSocial>>,
    linking: Option<Linking>,
    /// Device transport ids of this account's other devices that events are handed to live.
    siblings: Vec<String>,
    on_change: js_sys::Function,
}

/// One browser device: a device key, a relay-only node, and (once linked) the engine.
#[wasm_bindgen]
pub struct WebSession {
    inner: Rc<RefCell<Inner>>,
    node: WebNode,
    /// Keeps the inbound trampoline alive for as long as the node can call it.
    _inbound: Closure<dyn FnMut(String, js_sys::Uint8Array)>,
}

#[wasm_bindgen]
impl WebSession {
    /// Bring a device online under `device_seed` (32 bytes of this device's own key material —
    /// never an account seed) through the circle relay at `relay_url`. `on_change` is called with
    /// no arguments whenever the engine's state changed (a new event arrived, the device linked).
    pub async fn start(device_seed: &[u8], relay_url: String, on_change: js_sys::Function) -> Result<WebSession, JsError> {
        let device_seed = secret32(device_seed)?;
        let inner = Rc::new(RefCell::new(Inner { device_seed, social: None, linking: None, siblings: Vec::new(), on_change }));
        let inbound = {
            let inner = inner.clone();
            Closure::<dyn FnMut(String, js_sys::Uint8Array)>::new(move |from: String, bytes: js_sys::Uint8Array| {
                on_frame(&inner, &from, &bytes.to_vec());
            })
        };
        // The transport identity is the device's NODE key, exactly as on native (`Node::spawn(
        // identity.node_secret_bytes(), …)`), so the relay and peers see one id per device.
        let node_secret = Identity::from_seed(&device_seed).node_secret_bytes();
        let callback: js_sys::Function = inbound.as_ref().unchecked_ref::<js_sys::Function>().clone();
        let node = WebNode::spawn(&node_secret, relay_url, callback).await?;
        node.online().await;
        Ok(WebSession { inner, node, _inbound: inbound })
    }

    /// This device's transport id.
    #[wasm_bindgen(js_name = deviceIdHex)]
    pub fn device_id_hex(&self) -> String {
        self.node.node_id_hex()
    }

    /// Has a primary device authorized this one?
    #[wasm_bindgen(js_name = isLinked)]
    pub fn is_linked(&self) -> bool {
        self.inner.borrow().social.is_some()
    }

    /// Link this tab to an account: present a `haven-enroll:` ticket minted by one of the account's
    /// devices, and wait for that device's owner to approve. Resolves with the account id (hex) once
    /// the grant has passed every check in core (MAC under the ticket secret, account bundle matches
    /// the ticket, the credential names this device, the roster authorizes it, the self-sync grant
    /// opens). The master seed is never part of this exchange.
    pub async fn link(&self, ticket_text: String, device_name: String) -> Result<String, JsError> {
        let ticket = enroll::enroll_ticket_parse(ticket_text).map_err(err)?;
        let primary = hex(&ticket.primary_device);
        let request = {
            let st = self.inner.borrow();
            if st.social.is_some() {
                return Err(JsError::new("this device is already linked"));
            }
            let bundle = Identity::from_seed(&st.device_seed).public().to_bytes();
            enroll::enroll_build_request(ticket.secret.clone(), bundle, device_name, now_secs()).map_err(err)?
        };
        let (done, wait) = oneshot::channel();
        self.inner.borrow_mut().linking = Some(Linking { ticket, done });
        self.node.send_to_node(primary.clone(), wire::frame(wire::SEEDLESS_ENROLL_REQ, &request)).await?;
        match wait.await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => return Err(JsError::new(&e)),
            Err(_) => return Err(JsError::new("linking was abandoned")),
        }
        let st = &mut *self.inner.borrow_mut();
        st.siblings = vec![primary];
        Ok(st.social.as_ref().map(|s| s.my_node_hex()).unwrap_or_default())
    }

    /// Author a text post to a circle and hand it to this account's other online devices.
    pub async fn post(&self, circle_id: String, body: String) -> Result<(), JsError> {
        let (frames, siblings) = {
            let st = self.inner.borrow();
            let social = st.social.as_ref().ok_or_else(|| JsError::new("not linked"))?;
            social.post(circle_id.clone(), body, vec![], None, None, false, false, now_ms()).map_err(err)?;
            // The sync bundle carries the roster, the key commit and my events — self-sufficient, so
            // a sibling that has never heard from this device can open the post it contains.
            let frames: Vec<Vec<u8>> = social
                .sync_envelopes(circle_id.clone())
                .iter()
                .map(|env| wire::frame(wire::EVENT, &wire::event_payload(&circle_id, env)))
                .collect();
            (frames, st.siblings.clone())
        };
        for to in siblings {
            for f in &frames {
                self.node.send_to_node(to.clone(), f.clone()).await?;
            }
        }
        Ok(())
    }

    /// A circle's feed as JSON: `[{id, author, isMe, createdAt, body}]`, newest first as the engine
    /// orders it.
    pub fn feed(&self, circle_id: String) -> Result<String, JsError> {
        let st = self.inner.borrow();
        let social = st.social.as_ref().ok_or_else(|| JsError::new("not linked"))?;
        let items: Vec<String> = social
            .feed(circle_id, now_ms(), None)
            .iter()
            .map(|i| {
                format!(
                    r#"{{"id":{},"author":{},"isMe":{},"createdAt":{},"body":{}}}"#,
                    json_str(&i.id),
                    json_str(&i.author_short),
                    i.is_me,
                    i.created_at,
                    json_str(&i.body)
                )
            })
            .collect();
        Ok(format!("[{}]", items.join(",")))
    }

    /// Take the device offline.
    pub async fn close(&self) {
        self.node.close().await;
    }
}

fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c == '\u{2028}' || c == '\u{2029}' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Every inbound frame lands here. Nothing below trusts `from` beyond what the frame's own
/// cryptography establishes: a grant must open under the pending ticket, an event must open under
/// a circle key and verify against a roster.
fn on_frame(inner: &Rc<RefCell<Inner>>, _from: &str, frame: &[u8]) {
    let Some((&kind, body)) = frame.split_first() else { return };
    let changed = match kind {
        wire::SEEDLESS_ENROLL_GRANT => accept_grant(inner, body),
        wire::EVENT => {
            let st = inner.borrow();
            match (st.social.as_ref(), wire::parse_event(body)) {
                (Some(social), Some(ev)) => social.receive(ev.circle_id, ev.envelope).unwrap_or(false),
                _ => false,
            }
        }
        _ => false,
    };
    if changed {
        let cb = inner.borrow().on_change.clone();
        let _ = cb.call0(&JsValue::NULL);
    }
}

fn accept_grant(inner: &Rc<RefCell<Inner>>, body: &[u8]) -> bool {
    let st = &mut *inner.borrow_mut();
    if st.social.is_some() {
        return false; // only a linking device accepts a grant, and only once
    }
    let Some(linking) = st.linking.take() else { return false };
    let opened = enroll::enroll_open_grant(st.device_seed.to_vec(), clone_ticket(&linking.ticket), body.to_vec())
        .map_err(|e| format!("{e:?}"))
        .and_then(|grant| {
            let social = HavenSocial::new_seedless(grant.account_bundle, st.device_seed.to_vec()).map_err(|e| format!("{e:?}"))?;
            // Install the primary-signed roster verbatim (A3): it is what authorizes this device.
            if !social.ingest_roster_wire(grant.roster_wire) {
                return Err("the granted roster was refused".to_string());
            }
            Ok(social)
        });
    match opened {
        Ok(social) => {
            st.social = Some(social);
            let _ = linking.done.send(Ok(()));
            true
        }
        Err(_) => {
            // A bad grant is not fatal — anyone who can reach this node can send frame 29. Keep
            // waiting for the real one.
            st.linking = Some(linking);
            false
        }
    }
}

fn clone_ticket(t: &EnrollTicketFfi) -> EnrollTicketFfi {
    EnrollTicketFfi {
        account_id: t.account_id.clone(),
        verification: t.verification.clone(),
        secret: t.secret.clone(),
        primary_device: t.primary_device.clone(),
        issued_at: t.issued_at,
        relays: t.relays.clone(),
    }
}
