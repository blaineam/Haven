//! Borrow the WebView's encoder from the import thread.
//!
//! WHY THIS EXISTS. Every other desktop media path optimizes in the WEBVIEW, because that is the
//! only place this app has a codec at all (`src-tauri` carries none — see the CODEC DIVERGENCE note
//! in `reoptimize.rs`). The importer runs headless on its own thread precisely so it survives the
//! sheet being closed and the app being quit, and that isolation is what cost it optimization: it
//! sealed archive bytes exactly as they came out of the zip. Photos landed at full size and video
//! landed with no poster still, which is why imported stories had nothing to show in a ring.
//!
//! So the thread ASKS. A request is emitted as an event carrying a job id; the frontend does the
//! work with the same helpers the composer uses and calls `instagram_encoded` back; the thread
//! blocks on a channel until that arrives.
//!
//! DIRECTION DIFFERS BY KIND, and not arbitrarily:
//!
//!   * **Stills go out as bytes.** They are small, and the WebView has to hold the pixels to
//!     downscale them and mint the ≤32 KB `thumb:` companion.
//!   * **Video is sealed FIRST and only then asked about.** A reel can be hundreds of megabytes and
//!     base64 inflates it by a third; the file→file seal exists specifically so that never becomes
//!     a string in this process. The WebView reads the sealed ref back through `media_data_url` and
//!     returns only a POSTER. The clip itself is never re-encoded — the WebView's encoder emits
//!     VP8/Opus in WebM, which Apple's player cannot decode, so re-encoding would replace playable
//!     media with media the rest of the circle cannot open.
//!
//! FAILURE IS ALWAYS FINE. Every request has a timeout and every caller falls back to the raw seal.
//! A closed window, a refused file, a decode error or a quit frontend degrades the import to
//! exactly what it did before this module existed — it must never stall it.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, SyncSender};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use crate::engine::Engine;

/// What the frontend hands back: the refs to attach, in order. The content ref first, then any
/// marker companion (`thumb:<ref>:<thumb>`, `poster:<video>:<still>`) — the same shapes the
/// composer already posts, so imported media is indistinguishable from hand-posted media.
pub type Refs = Vec<String>;

fn pending() -> &'static Mutex<HashMap<u64, SyncSender<Option<Refs>>>> {
    static P: OnceLock<Mutex<HashMap<u64, SyncSender<Option<Refs>>>>> = OnceLock::new();
    P.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_JOB: AtomicU64 = AtomicU64::new(1);

/// Optimize + store one still. `None` = do it the old way.
pub fn image(engine: &Engine, circle_id: &str, bytes: &[u8]) -> Option<Refs> {
    use base64::Engine as _;
    let data = base64::engine::general_purpose::STANDARD.encode(bytes);
    request(
        engine,
        serde_json::json!({ "kind": "image", "circleId": circle_id, "dataBase64": data }),
        // Generous: a large still decodes, downscales, re-encodes and mints a thumb, and the
        // WebView is also painting a feed while it does.
        Duration::from_secs(45),
    )
}

/// Mint a poster still for a video that is ALREADY sealed. `None` = the video simply has no poster,
/// which is what imported video had in every build before this.
pub fn poster(engine: &Engine, circle_id: &str, video_ref: &str) -> Option<Refs> {
    request(
        engine,
        serde_json::json!({ "kind": "poster", "circleId": circle_id, "ref": video_ref }),
        // Longer: this reads the sealed clip back out, decodes it and seeks for a drawable frame.
        Duration::from_secs(90),
    )
}

fn request(engine: &Engine, mut payload: serde_json::Value, timeout: Duration) -> Option<Refs> {
    let job = NEXT_JOB.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = sync_channel::<Option<Refs>>(1);
    pending().lock().ok()?.insert(job, tx);
    if let Some(obj) = payload.as_object_mut() {
        obj.insert("job".into(), serde_json::json!(job));
    }
    engine.emit_event("haven:ig-encode", payload);

    let out = rx.recv_timeout(timeout);
    // Drop the slot whatever happened, so a late reply finds nothing rather than a stale sender.
    if let Ok(mut p) = pending().lock() {
        p.remove(&job);
    }
    match out {
        Ok(v) => v,
        Err(_) => {
            log::warn!("ig-encode: job {job} timed out or the frontend is gone — sealing raw");
            None
        }
    }
}

/// The frontend answering. `None` means "couldn't" — the caller falls back.
pub fn fulfill(job: u64, refs: Option<Refs>) {
    let tx = pending().lock().ok().and_then(|mut p| p.remove(&job));
    if let Some(tx) = tx {
        let _ = tx.send(refs); // the receiver may already have timed out; that is not an error
    }
}
