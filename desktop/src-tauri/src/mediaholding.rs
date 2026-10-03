//! The pure half of "which relay holds which media blob" — the decisions behind the backup ledger
//! (`Engine::mark_media_backed_up`). Apple `MediaHolding.swift` / Android `MediaHolding.kt` parity.
//!
//! Field report (2.0.0-rc.3, iPhone; the same pattern existed here): after "Load history from your
//! relays" pulled hundreds of posts and their media, the device kept working hard afterwards.
//!   1. The ledger was written only on the upload/probe paths — a blob just downloaded, complete and
//!      opened, from relay X was not recorded as held by X.
//!   2. So the 2-minute backfill re-offered every one of those refs, and the probe asked each relay
//!      "do you hold it?" with a FULL GET of the blob, re-downloading every recovered photo from the
//!      relay it had just come from (and re-sealing it for any relay that lacked it).

use std::future::Future;

/// The ledger destination to record as HOLDING a ref after a download from `source` (a relay node
/// hex, or "s3") — ONLY when the blob was complete AND opened. A partial or an undecryptable copy
/// proves nothing about what the source holds, and a ledger entry is never revisited.
pub fn holder_to_record(source: Option<&str>, complete: bool, opened: bool) -> Option<String> {
    match source {
        Some(s) if complete && opened && !s.is_empty() => Some(s.to_string()),
        _ => None,
    }
}

/// One `HEAD /k/<key>` answer. `Unsupported` = 400/405/501 (an old relay or a proxy) → GET fallback.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Head {
    Present,
    Absent,
    Unsupported,
    Refused,
    Unreachable,
}

/// One GET answer (the fallback probe, and the tiny manifest read).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Fetch {
    Data(Vec<u8>),
    Miss,
    Refused,
    Unreachable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Holds every window → ledger it, never ask again.
    Complete,
    /// Manifest present, tail window missing → re-upload.
    Incomplete,
    Absent,
    Refused,
    Unreachable,
}

/// Does a relay hold a COMPLETE copy, as cheaply as possible? HEAD the manifest key (absent →
/// `Absent`); HEAD chunk 0 (absent → unchunked, presence is completeness); chunked → GET the
/// ~100-byte manifest for the window count and HEAD the LAST window (the old tail check). A relay
/// that won't answer HEAD gets exactly the old GET probe. The second value counts GETs of a key that
/// may be a whole blob (the QA "probeGet" signal); the tiny manifest GET is not one.
pub async fn probe<H, HF, G, GF>(
    manifest_key: &str,
    chunk_key: impl Fn(usize) -> String,
    head: H,
    get: G,
    chunk_count: impl Fn(&[u8]) -> Option<usize>,
) -> (Verdict, u32)
where
    H: Fn(String) -> HF,
    HF: Future<Output = Head>,
    G: Fn(String) -> GF,
    GF: Future<Output = Fetch>,
{
    match head(manifest_key.to_string()).await {
        Head::Refused => return (Verdict::Refused, 0),
        Head::Unreachable => return (Verdict::Unreachable, 0),
        Head::Absent => return (Verdict::Absent, 0),
        Head::Unsupported => return legacy_probe(manifest_key, &chunk_key, &get, &chunk_count).await,
        Head::Present => {}
    }
    match head(chunk_key(0)).await {
        Head::Absent => return (Verdict::Complete, 0), // not chunked → presence is completeness
        Head::Refused => return (Verdict::Refused, 0),
        Head::Unreachable => return (Verdict::Unreachable, 0),
        Head::Unsupported => return legacy_probe(manifest_key, &chunk_key, &get, &chunk_count).await,
        Head::Present => {}
    }
    let manifest = match get(manifest_key.to_string()).await {
        Fetch::Refused => return (Verdict::Refused, 0),
        Fetch::Unreachable => return (Verdict::Unreachable, 0),
        Fetch::Miss => return (Verdict::Absent, 0), // vanished between the two asks
        Fetch::Data(m) => m,
    };
    let n = match chunk_count(&manifest) {
        Some(n) if n > 0 => n,
        _ => return (Verdict::Complete, 0),
    };
    match head(chunk_key(n - 1)).await {
        Head::Present => (Verdict::Complete, 0),
        Head::Absent => (Verdict::Incomplete, 0),
        Head::Refused => (Verdict::Refused, 0),
        Head::Unreachable | Head::Unsupported => (Verdict::Unreachable, 0),
    }
}

async fn legacy_probe<G, GF>(
    manifest_key: &str,
    chunk_key: &impl Fn(usize) -> String,
    get: &G,
    chunk_count: &impl Fn(&[u8]) -> Option<usize>,
) -> (Verdict, u32)
where
    G: Fn(String) -> GF,
    GF: Future<Output = Fetch>,
{
    let manifest = match get(manifest_key.to_string()).await {
        Fetch::Refused => return (Verdict::Refused, 1),
        Fetch::Unreachable => return (Verdict::Unreachable, 1),
        Fetch::Miss => return (Verdict::Absent, 1),
        Fetch::Data(m) => m,
    };
    let n = match chunk_count(&manifest) {
        Some(n) if n > 0 => n,
        _ => return (Verdict::Complete, 1),
    };
    match get(chunk_key(n - 1)).await {
        Fetch::Data(d) if !d.is_empty() => (Verdict::Complete, 2),
        _ => (Verdict::Incomplete, 2),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct Fake {
        store: HashMap<String, Vec<u8>>,
        no_head: bool,
        heads: u32,
        gets: Vec<String>,
    }
    const MAGIC: &[u8] = b"HVCHUNK1\n";
    fn manifest(n: usize) -> Vec<u8> {
        [MAGIC, format!("{{\"chunks\":{n}}}").as_bytes()].concat()
    }
    fn chunks(b: &[u8]) -> Option<usize> {
        let body = b.strip_prefix(MAGIC)?;
        let v: serde_json::Value = serde_json::from_slice(body).ok()?;
        v.get("chunks")?.as_u64().map(|n| n as usize)
    }
    async fn run(f: Arc<Mutex<Fake>>) -> (Verdict, u32) {
        let (fh, fg) = (f.clone(), f.clone());
        probe(
            "m",
            |i| format!("m.p/{i}"),
            move |k| {
                let f = fh.clone();
                async move {
                    let mut f = f.lock().unwrap();
                    f.heads += 1;
                    if f.no_head {
                        Head::Unsupported
                    } else if f.store.contains_key(&k) {
                        Head::Present
                    } else {
                        Head::Absent
                    }
                }
            },
            move |k| {
                let f = fg.clone();
                async move {
                    let mut f = f.lock().unwrap();
                    f.gets.push(k.clone());
                    f.store.get(&k).cloned().map(Fetch::Data).unwrap_or(Fetch::Miss)
                }
            },
            chunks,
        )
        .await
    }

    #[test]
    fn restore_marks_the_serving_relay_only_on_a_complete_opened_download() {
        assert_eq!(holder_to_record(Some("aa"), true, true).as_deref(), Some("aa"));
        assert_eq!(holder_to_record(Some("s3"), true, true).as_deref(), Some("s3"));
        assert_eq!(holder_to_record(Some("aa"), false, true), None, "partial");
        assert_eq!(holder_to_record(Some("aa"), true, false), None, "undecryptable");
        assert_eq!(holder_to_record(None, true, true), None);
    }

    #[tokio::test]
    async fn probe_of_an_unchunked_photo_downloads_nothing() {
        let f = Arc::new(Mutex::new(Fake::default()));
        f.lock().unwrap().store.insert("m".into(), vec![0; 3_000_000]);
        assert_eq!(run(f.clone()).await, (Verdict::Complete, 0));
        assert!(f.lock().unwrap().gets.is_empty(), "the old probe GET the whole photo");
    }

    #[tokio::test]
    async fn probe_of_a_chunked_blob_reads_only_the_manifest_and_catches_a_missing_tail() {
        let f = Arc::new(Mutex::new(Fake::default()));
        {
            let mut g = f.lock().unwrap();
            g.store.insert("m".into(), manifest(3));
            g.store.insert("m.p/0".into(), vec![1]);
            g.store.insert("m.p/1".into(), vec![1]);
        }
        assert_eq!(run(f.clone()).await, (Verdict::Incomplete, 0));
        f.lock().unwrap().store.insert("m.p/2".into(), vec![1]);
        assert_eq!(run(f.clone()).await, (Verdict::Complete, 0));
        assert!(f.lock().unwrap().gets.iter().all(|k| k == "m"), "only the manifest is ever GET");
    }

    #[tokio::test]
    async fn absent_is_one_head_and_old_relays_fall_back_to_get() {
        let f = Arc::new(Mutex::new(Fake::default()));
        assert_eq!(run(f.clone()).await, (Verdict::Absent, 0));
        assert_eq!(f.lock().unwrap().heads, 1);
        let old = Arc::new(Mutex::new(Fake { no_head: true, ..Default::default() }));
        old.lock().unwrap().store.insert("m".into(), vec![0; 10]);
        assert_eq!(run(old).await, (Verdict::Complete, 1), "an old relay keeps working at the old cost");
    }

    #[tokio::test]
    async fn refusal_is_not_absence() {
        let v = probe("m", |i| i.to_string(), |_| async { Head::Refused }, |_| async { Fetch::Miss }, |_| None).await;
        assert_eq!(v.0, Verdict::Refused);
        let v = probe("m", |i| i.to_string(), |_| async { Head::Unsupported }, |_| async { Fetch::Refused }, |_| None).await;
        assert_eq!(v.0, Verdict::Refused);
    }
}
