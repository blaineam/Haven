//! Haven running in a tab: the shared client [`Engine`] (`haven-client` — the same code the
//! desktop app runs) on a relay-only node, with the page as its host.
//!
//! A browser device is always a **seedless linked device**: it is given a `haven-enroll:` ticket by
//! one of the account's devices, proves possession of it, and receives a credential, the signed
//! roster and the self-sync key — never the account's master seed. There is no web sign-up.

use std::cell::RefCell;
use std::sync::Arc;

use haven_client::engine::{self, Engine};
use haven_client::host::{AppHandle, Host};
use haven_client::pairing::Pairing;
use haven_client::roster::Seedless;
use haven_client::store::{self, Paths};
use wasm_bindgen::prelude::*;

/// The page, as the engine sees it: UI events go to one callback as `(name, json)`.
struct PageHost {
    on_event: js_sys::Function,
}

// SAFETY: wasm32-unknown-unknown without the atomics feature has exactly one thread; the engine's
// `Host` contract asks for `Send + Sync` because native hosts are called from many. A `Function`
// never leaves the thread it was created on here.
unsafe impl Send for PageHost {}
unsafe impl Sync for PageHost {}

impl Host for PageHost {
    fn emit(&self, event: &str, payload: serde_json::Value) -> Result<(), String> {
        self.on_event
            .call2(&JsValue::NULL, &JsValue::from_str(event), &JsValue::from_str(&payload.to_string()))
            .map(|_| ())
            .map_err(|e| format!("{e:?}"))
    }

    fn notify(&self, title: &str, body: &str) {
        // The page decides how to surface it (Notifications API when permitted, a toast otherwise).
        let payload = serde_json::json!({ "title": title, "body": body });
        let _ = self.emit("haven:os-notify", payload);
    }
}

fn js_err(e: impl std::fmt::Display) -> JsError {
    JsError::new(&e.to_string())
}

/// The data dir of the active identity, if this browser has one.
fn active_paths() -> Result<Option<Paths>, JsError> {
    let base = Paths::resolve().map_err(js_err)?;
    let ids = store::Identities::load(&base);
    let Some(entry) = ids.active_entry().cloned() else { return Ok(None) };
    Paths::resolve_for(&entry.dir).map(Some).map_err(js_err)
}

/// One Haven device in this tab.
#[wasm_bindgen]
pub struct WebApp {
    host: AppHandle,
    engine: RefCell<Option<Arc<Engine>>>,
    /// Scan-to-link: this browser is showing a `haven-pair:` code and waiting to be answered.
    pairing: RefCell<Option<Arc<Pairing>>>,
}

#[wasm_bindgen]
impl WebApp {
    /// Create the app. `on_event(name, json)` receives every engine UI event (`haven:changed`,
    /// `haven:enrolled`, `haven:notify`, `haven:call`, …). Nothing is started yet: call
    /// [`set_relays`](Self::set_relays) then [`boot`](Self::boot).
    #[wasm_bindgen(constructor)]
    pub fn new(on_event: js_sys::Function) -> WebApp {
        WebApp {
            host: AppHandle::new(Arc::new(PageHost { on_event })),
            engine: RefCell::new(None),
            pairing: RefCell::new(None),
        }
    }

    /// The relay front door(s) this page was served from (DERP base URLs). They stay in the
    /// node's relay map alongside whatever relays the linked account knows. Must be set before
    /// [`boot`](Self::boot): the relay map is fixed when the node binds.
    #[wasm_bindgen(js_name = setRelays)]
    pub fn set_relays(&self, derp_urls: Vec<String>) {
        haven_client::net::set_origin_relays(derp_urls);
    }

    /// How this browser describes itself when it asks to be linked ("Firefox on Windows"). The
    /// engine adds the web-device mark; the account signs the result into this device's credential.
    #[wasm_bindgen(js_name = setDeviceLabel)]
    pub fn set_device_label(&self, label: &str) {
        haven_client::roster::DeviceRoster::set_web_label(label);
    }

    /// Does this browser hold no identity yet (so the page must show the link screen)?
    #[wasm_bindgen(js_name = needsOnboarding)]
    pub fn needs_onboarding(&self) -> Result<bool, JsError> {
        Ok(active_paths()?.is_none())
    }

    /// Start the engine for the stored identity and bring its node online. Resolves `false` when
    /// there is no identity to boot. Once per page load: after `haven:enrolled` the page flushes
    /// storage and reloads, and the next boot builds the engine from the now-linked state — the
    /// same relaunch the desktop app does.
    pub async fn boot(&self) -> Result<bool, JsError> {
        if self.engine.borrow().is_some() {
            return Err(JsError::new("the engine is already running; reload the page to restart it"));
        }
        let Some(paths) = active_paths()? else { return Ok(false) };
        if !Seedless::is_enabled(&paths) {
            return Err(JsError::new("this browser's stored identity is not a linked device"));
        }
        let engine = Engine::new_seedless(paths).map_err(js_err)?;
        engine.set_app(self.host.clone());
        *self.engine.borrow_mut() = Some(engine.clone());
        engine.start().await;
        Ok(true)
    }

    /// Begin linking this browser to an account with a `haven-enroll:` ticket from one of its
    /// devices. Persists the linking state; then call [`boot`](Self::boot), which sends the request.
    /// `haven:enrolled` fires once that device's owner approves and the grant passes every check.
    #[wasm_bindgen(js_name = onboardLink)]
    pub fn onboard_link(&self, ticket_text: &str) -> Result<(), JsError> {
        engine::onboard_seedless(ticket_text).map_err(js_err)
    }

    /// Scan-to-link: make (or replace) the `haven-pair:` code this browser shows, for a device
    /// that already has the account to scan. `relay` is the front door this page came from — the
    /// only place this browser can be reached. The first call brings a node up under a fresh
    /// device key; later calls only issue a fresh code. `haven:pair-offer` fires when a device
    /// answers; then call [`pairFinish`](Self::pair_finish).
    #[wasm_bindgen(js_name = pairBegin)]
    pub async fn pair_begin(&self, relay: String) -> Result<String, JsError> {
        if self.engine.borrow().is_some() {
            return Err(JsError::new("this browser is already linked"));
        }
        let existing = self.pairing.borrow().clone();
        if let Some(p) = existing {
            return p.refresh().map_err(js_err);
        }
        let p = Pairing::begin(relay, self.host.clone()).await.map_err(js_err)?;
        let code = p.code();
        *self.pairing.borrow_mut() = Some(p);
        Ok(code)
    }

    /// Store the linking state for the offer that answered this browser's code (under the key the
    /// code named) and stop listening. Then flush storage and reload, as after
    /// [`onboardLink`](Self::onboard_link).
    #[wasm_bindgen(js_name = pairFinish)]
    pub async fn pair_finish(&self) -> Result<(), JsError> {
        let p = self.pairing.borrow().clone().ok_or_else(|| JsError::new("no code is showing"))?;
        p.finish().await.map_err(js_err)?;
        *self.pairing.borrow_mut() = None;
        Ok(())
    }

    /// Stop showing a code (the link screen was left). Safe to call when none is showing.
    #[wasm_bindgen(js_name = pairStop)]
    pub async fn pair_stop(&self) {
        let p = self.pairing.borrow_mut().take();
        if let Some(p) = p {
            p.stop().await;
        }
    }

    /// Run an engine command by name — the browser's end of the UI's `invoke(name, args)`. The
    /// arguments and the result are JSON text. Rejects with the bare string `"unknown-command"`
    /// for a name the engine does not have (the page's host layer answers those), and with the
    /// command's own message otherwise — the same contract the desktop app's `engine_invoke` has.
    pub async fn invoke(&self, name: String, args_json: String) -> Result<String, JsValue> {
        use haven_client::commands::{dispatch, DispatchError, Eng, NAMES};
        if !NAMES.contains(&name.as_str()) {
            return Err(JsValue::from_str("unknown-command"));
        }
        // Clone the handle out: nothing may stay borrowed across the await.
        let engine = self.engine.borrow().clone();
        let Some(engine) = engine else {
            return Err(JsValue::from_str("the engine is not running yet"));
        };
        let args: serde_json::Value = serde_json::from_str(&args_json).map_err(|e| JsValue::from_str(&e.to_string()))?;
        match dispatch(Eng(&engine), &name, &args).await {
            Ok(v) => Ok(v.to_string()),
            Err(DispatchError::Unknown) => Err(JsValue::from_str("unknown-command")),
            Err(e) => Err(JsValue::from_str(&e.to_string())),
        }
    }

    /// `{seedless, linked, linking}`.
    pub fn status(&self) -> Result<String, JsError> {
        let (seedless, linked, linking) = self.engine()?.seedless_status();
        Ok(serde_json::json!({ "seedless": seedless, "linked": linked, "linking": linking }).to_string())
    }

    /// The account's id (hex).
    #[wasm_bindgen(js_name = accountIdHex)]
    pub fn account_id_hex(&self) -> Result<String, JsError> {
        Ok(self.engine()?.node_id_hex())
    }

    /// Author a text post to a circle.
    pub fn post(&self, circle_id: String, body: String) -> Result<(), JsError> {
        self.engine()?.post(circle_id, body, vec![], None, false, None);
        Ok(())
    }

    /// A circle's feed as JSON: `[{id, author, isMe, createdAt, body}]`.
    pub fn feed(&self, circle_id: &str) -> Result<String, JsError> {
        let items: Vec<serde_json::Value> = self
            .engine()?
            .feed(circle_id)
            .iter()
            .map(|i| {
                serde_json::json!({
                    "id": i.id, "author": i.author_short, "isMe": i.is_me, "createdAt": i.created_at, "body": i.body,
                })
            })
            .collect();
        Ok(serde_json::Value::Array(items).to_string())
    }
}

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = console, js_name = log)]
    fn console_log(line: &str);
}

/// The engine's diagnostics, written to the page's own console. They never leave the browser —
/// the same rule as the apps' on-device trace files.
struct ConsoleLog;

impl log::Log for ConsoleLog {
    fn enabled(&self, m: &log::Metadata) -> bool {
        m.level() <= log::max_level()
    }
    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            console_log(&format!("[haven {}] {}", record.level(), record.args()));
        }
    }
    fn flush(&self) {}
}

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = console, js_name = error)]
    fn console_error(line: &str);
}

/// Runs when the module is instantiated. A Rust panic in a browser is otherwise a bare
/// `RuntimeError: unreachable` with no message and no place; say what panicked and where, in the
/// page's own console (it goes nowhere else).
#[wasm_bindgen(start)]
pub fn on_load() {
    std::panic::set_hook(Box::new(|info| console_error(&format!("[haven panic] {info}"))));
}

/// Send the engine's log lines to the console at `level` (`"error"`, `"warn"`, `"info"`,
/// `"debug"`); anything else turns them off. Off by default.
#[wasm_bindgen(js_name = setLogLevel)]
pub fn set_log_level(level: &str) {
    static LOGGER: ConsoleLog = ConsoleLog;
    let _ = log::set_logger(&LOGGER);
    log::set_max_level(level.parse().unwrap_or(log::LevelFilter::Off));
}

/// The engine self-test as the UI's "self test" command reports it (JSON).
#[wasm_bindgen(js_name = engineSelfTestReport)]
pub fn engine_self_test_report() -> String {
    let r = haven_ffi::self_test();
    serde_json::json!({
        "identity_ok": r.identity_ok,
        "hybrid_kem_ok": r.hybrid_kem_ok,
        "signature_ok": r.signature_ok,
        "link_ok": r.link_ok,
        "all_ok": r.all_ok,
        "node_id_hex": r.node_id_hex,
        "summary": r.summary,
    })
    .to_string()
}

/// This build's version.
#[wasm_bindgen]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Keep this page off the push worker (for harnesses driving throwaway identities).
#[wasm_bindgen(js_name = setPushOff)]
pub fn set_push_off(off: bool) {
    haven_client::netgate::set_push_off(off);
}

/// Load one file into the engine's storage at startup, before [`WebApp::boot`]. The page calls
/// this for every record it persisted (see `web-client/storage.js`).
#[wasm_bindgen(js_name = storagePreload)]
pub fn storage_preload(path: String, data: Vec<u8>, modified_ms: f64) {
    let modified = web_time::UNIX_EPOCH + std::time::Duration::from_millis(modified_ms.max(0.0) as u64);
    haven_client::fs::preload(path, data, modified);
}

/// Everything the engine wrote or removed since the last call, for the page to persist:
/// an array of `[path, Uint8Array]` (write) and `[path, null]` (remove), each path once.
#[wasm_bindgen(js_name = storageTakeChanges)]
pub fn storage_take_changes() -> js_sys::Array {
    use haven_client::fs::Change;
    let out = js_sys::Array::new();
    for change in haven_client::fs::take_changes() {
        let (path, data) = match change {
            // A file removed again since the change was recorded is reported as a removal.
            Change::Put(p) => {
                let data = haven_client::fs::snapshot(&p);
                (p, data)
            }
            Change::Remove(p) => (p, None),
        };
        let pair = js_sys::Array::new();
        pair.push(&JsValue::from_str(&path.to_string_lossy()));
        pair.push(&match data {
            Some(bytes) => js_sys::Uint8Array::from(bytes.as_slice()).into(),
            None => JsValue::NULL,
        });
        out.push(&pair);
    }
    out
}

impl WebApp {
    fn engine(&self) -> Result<Arc<Engine>, JsError> {
        self.engine.borrow().clone().ok_or_else(|| JsError::new("the engine is not running — call boot() first"))
    }
}
