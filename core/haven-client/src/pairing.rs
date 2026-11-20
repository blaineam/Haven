//! The NEW device's side of scan-to-link (`haven_p2p::pair`): show a `haven-pair:` code, wait for
//! a device that holds the account to answer it with a ticket, then link with that ticket.
//!
//! This runs before there is any account or engine — the device has only a transport key it just
//! made. While a code is showing it listens on one relay and accepts exactly ONE kind of frame
//! from anyone: a [`wire::PAIR_OFFER`] that opens under the code on screen. Everything else is
//! dropped unread. The first offer that opens wins; the page then stores the ticket and restarts
//! into the ordinary seedless-linking engine, under the SAME transport key (the ticket is bound to
//! it — see `Engine::link_scanned_device`).
//!
//! What a watcher of the screen can do is in `haven_p2p::pair`'s module docs: make this device
//! join THEIR account (visible, and worth nothing to them), never get a device onto someone else's.

use std::sync::{Arc, Weak};

use crate::transport::InboundListener;
use parking_lot::Mutex;

use crate::engine::{onboard_seedless_as, PAIR_CODE_TTL_SECS};
use crate::host::AppHandle;
use crate::transport::HavenNode;
use crate::wire;

/// Emitted (no payload) when an offer has been accepted and [`Pairing::finish`] can be called.
pub const EVENT_OFFER: &str = "haven:pair-offer";

fn now_secs() -> u64 {
    crate::engine::now_ms() / 1000
}

/// A device that is showing a code.
pub struct Pairing {
    device_seed: Vec<u8>,
    device_bundle: Vec<u8>,
    relay: String,
    host: AppHandle,
    node: Mutex<Option<Arc<HavenNode>>>,
    /// The code on screen. Replaced by [`refresh`](Self::refresh); an offer for an older code no
    /// longer opens.
    code: Mutex<String>,
    /// The ticket from the offer that was accepted.
    ticket: Mutex<Option<String>>,
}

struct Listener(Weak<Pairing>);

impl InboundListener for Listener {
    fn on_inbound(&self, _from_hex: String, payload: Vec<u8>) {
        let Some(pairing) = self.0.upgrade() else { return };
        pairing.on_frame(&payload);
    }
}

impl Pairing {
    /// Make this device's transport key, bring a node up on the relay map already configured
    /// (`crate::net`), and issue the first code naming `relay` as the place to reach it.
    pub async fn begin(relay: String, host: AppHandle) -> Result<Arc<Self>, String> {
        let account = haven_ffi::Account::generate();
        let device_seed = account.secret_seed();
        let device_bundle = account.public_bundle();
        let me = Arc::new(Self {
            device_seed: device_seed.clone(),
            device_bundle,
            relay: relay.trim().trim_end_matches('/').to_string(),
            host,
            node: Mutex::new(None),
            code: Mutex::new(String::new()),
            ticket: Mutex::new(None),
        });
        let listener: Arc<dyn InboundListener> = Arc::new(Listener(Arc::downgrade(&me)));
        let node = HavenNode::start(device_seed, listener).await.map_err(|e| e.to_string())?;
        // A code is only worth showing once this device can actually be reached on the relay.
        #[cfg(target_arch = "wasm32")]
        if crate::rt::timeout(std::time::Duration::from_secs(20), node.online()).await.is_err() {
            node.shutdown().await;
            return Err("could not reach the relay".into());
        }
        *me.node.lock() = Some(node);
        me.refresh()?;
        Ok(me)
    }

    /// The code to show (QR + text).
    pub fn code(&self) -> String {
        self.code.lock().clone()
    }

    /// Replace the code with a fresh one (new secret, new timestamp) — codes last ten minutes, and
    /// a page left open must not keep an old one alive.
    pub fn refresh(&self) -> Result<String, String> {
        let code = haven_ffi::enroll::pair_code_issue(self.device_bundle.clone(), now_secs(), self.relay.clone())
            .map_err(|e| e.to_string())?;
        *self.code.lock() = code.clone();
        Ok(code)
    }

    /// Has an offer been accepted?
    pub fn offered(&self) -> bool {
        self.ticket.lock().is_some()
    }

    fn on_frame(&self, frame: &[u8]) {
        // The one frame a device with no account accepts.
        let Some((&wire::PAIR_OFFER, body)) = frame.split_first() else { return };
        if self.offered() {
            return; // the first offer that opened won
        }
        let code = self.code();
        let Ok(ticket) = haven_ffi::enroll::pair_offer_open(code, body.to_vec(), now_secs(), PAIR_CODE_TTL_SECS)
        else {
            return; // not sealed for the code on screen: say nothing, keep waiting
        };
        // It must be a ticket this device could actually link with, or it is not an offer.
        if haven_ffi::enroll::enroll_ticket_parse(ticket.clone()).is_err() {
            return;
        }
        *self.ticket.lock() = Some(ticket);
        let _ = self.host.emit(EVENT_OFFER, ());
    }

    /// Store the linking state for the accepted offer — under this device's existing key — and
    /// stop listening. The caller then restarts into the linking engine, exactly as after
    /// `onboard_seedless`.
    pub async fn finish(&self) -> Result<(), String> {
        let ticket = self.ticket.lock().clone().ok_or("no device has answered this code yet")?;
        onboard_seedless_as(&ticket, Some(&self.device_seed))?;
        self.stop().await;
        Ok(())
    }

    /// Stop listening (the code on screen is dead from here on).
    pub async fn stop(&self) {
        let node = self.node.lock().take();
        if let Some(node) = node {
            node.shutdown().await;
        }
    }

}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::covtest_util::{engine, tmp_paths};
    use crate::host::Host;

    #[derive(Default)]
    struct Events(Mutex<Vec<String>>);
    impl Host for Events {
        fn emit(&self, event: &str, _payload: serde_json::Value) -> Result<(), String> {
            self.0.lock().push(event.to_string());
            Ok(())
        }
        fn notify(&self, _title: &str, _body: &str) {}
    }

    /// A device showing a code, with no node (nothing here touches the network).
    fn showing() -> (Arc<Pairing>, Arc<Events>) {
        let events = Arc::new(Events::default());
        let account = haven_ffi::Account::generate();
        let p = Arc::new(Pairing {
            device_seed: account.secret_seed(),
            device_bundle: account.public_bundle(),
            relay: "https://relay.example.test".into(),
            host: AppHandle::new(events.clone()),
            node: Mutex::new(None),
            code: Mutex::new(String::new()),
            ticket: Mutex::new(None),
        });
        p.refresh().unwrap();
        (p, events)
    }

    fn offer(code: &str, ticket: &str) -> Vec<u8> {
        wire::frame(wire::PAIR_OFFER, &haven_ffi::enroll::pair_offer_build(code.into(), ticket.into(), now_secs()).unwrap())
    }

    #[tokio::test]
    async fn only_an_offer_for_the_code_on_screen_is_accepted_and_only_the_first() {
        let (primary, _) = engine(61);
        let ticket = primary.mint_enroll_ticket().unwrap();
        let (p, events) = showing();
        let code = p.code();
        assert!(code.starts_with("haven-pair:"));

        // Anything that is not a pair offer is dropped unread — a device with no account takes
        // no other frame from anyone.
        p.on_frame(&[]);
        p.on_frame(&wire::frame(wire::EVENT, b"whatever"));
        p.on_frame(&wire::frame(wire::SEEDLESS_ENROLL_GRANT, b"whatever"));
        // An offer sealed for some other code.
        let (other, _) = showing();
        p.on_frame(&offer(&other.code(), &ticket));
        // An offer for this code that does not carry a ticket.
        p.on_frame(&offer(&code, "not a ticket"));
        assert!(!p.offered());
        assert!(events.0.lock().is_empty());

        p.on_frame(&offer(&code, &ticket));
        assert!(p.offered());
        assert_eq!(*events.0.lock(), vec![EVENT_OFFER.to_string()]);

        // A second offer changes nothing.
        let (stranger, _) = engine(62);
        let theirs = stranger.mint_enroll_ticket().unwrap();
        p.on_frame(&offer(&code, &theirs));
        assert_eq!(p.ticket.lock().clone().unwrap(), ticket);
        assert_eq!(events.0.lock().len(), 1);
    }

    #[tokio::test]
    async fn a_refreshed_code_kills_the_old_one() {
        let (primary, _) = engine(63);
        let ticket = primary.mint_enroll_ticket().unwrap();
        let (p, _) = showing();
        let old = p.code();
        let new = p.refresh().unwrap();
        assert_ne!(old, new);
        p.on_frame(&offer(&old, &ticket));
        assert!(!p.offered(), "an offer for the replaced code does not open");
        p.on_frame(&offer(&new, &ticket));
        assert!(p.offered());
    }

    #[tokio::test]
    async fn finishing_links_under_the_key_the_code_named() {
        let (primary, _) = engine(64);
        let ticket = primary.mint_enroll_ticket().unwrap();
        let (p, _) = showing();
        assert!(p.finish().await.is_err(), "nothing to finish before an offer");
        p.on_frame(&offer(&p.code(), &ticket));

        // `finish` writes to the real data tree; the same body against a scratch tree:
        let base = tmp_paths();
        let root = base.clone();
        crate::engine::onboard_seedless_in(&base, |_| Ok(root.clone()), &ticket, Some(&p.device_seed)).unwrap();
        let roster = crate::roster::DeviceRoster::load(&base);
        assert_eq!(roster.device_seed, p.device_seed, "the device keeps the key its code named");
        let s = crate::roster::Seedless::load(&base);
        assert!(s.enabled && !s.linked && s.pending_ticket.is_some());

        // A malformed key is refused before anything is stored.
        let fresh = tmp_paths();
        let fresh_root = fresh.clone();
        assert!(crate::engine::onboard_seedless_in(&fresh, |_| Ok(fresh_root.clone()), &ticket, Some(&[1, 2, 3])).is_err());
    }
}
