//! A tiny AWS Signature V4 S3 client (`put` / `get` / `list`) for Haven's **bring-your-own
//! storage** mailbox. Path-style addressing works against AWS S3, Cloudflare R2, Backblaze B2,
//! MinIO, and anything S3-compatible. The bucket holds only E2E-sealed blobs — the storage
//! provider never sees plaintext.
//!
//! This is the single Rust implementation meant to retire the per-platform S3 clients (the
//! Swift `S3Client`); it lives in `core/` so every client can adopt it. It is intentionally
//! NOT wired into `haven-p2p`/`haven-net`/`haven_ffi`, so the iOS/Android build is unaffected.

use std::collections::BTreeMap;

use anyhow::{anyhow, Context, Result};
use chrono::Utc;
use hmac::{Hmac, Mac};
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

// RFC 3986 unreserved = A-Za-z0-9 - _ . ~ — everything else is percent-encoded.
const ENC_QUERY: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'_').remove(b'.').remove(b'~');
// Same, but '/' is left literal inside a path.
const ENC_PATH: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'_').remove(b'.').remove(b'~').remove(b'/');

/// Connection + credentials for an S3-compatible bucket.
#[derive(Clone, Debug)]
pub struct S3Config {
    /// e.g. `https://s3.us-east-1.amazonaws.com` or an R2/B2/MinIO endpoint (no trailing slash).
    pub endpoint: String,
    pub region: String,
    pub bucket: String,
    pub access_key: String,
    pub secret_key: String,
    /// Key prefix all objects live under, e.g. `haven/mailbox`.
    pub prefix: String,
}

fn hmac(key: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut m = HmacSha256::new_from_slice(key).expect("hmac key");
    m.update(msg);
    m.finalize().into_bytes().to_vec()
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex::encode(h.finalize())
}

/// Compute the full `Authorization` header value for a SigV4-signed request. `headers` is the
/// exact set of headers to sign (lowercase names → values). Returns the `Authorization` value.
#[allow(clippy::too_many_arguments)]
fn sigv4_authorization(
    access: &str,
    secret: &str,
    region: &str,
    service: &str,
    method: &str,
    canonical_uri: &str,
    canonical_query: &str,
    headers: &BTreeMap<String, String>,
    payload_hash: &str,
    amz_date: &str,
    datestamp: &str,
) -> String {
    let canonical_headers: String = headers.iter().map(|(k, v)| format!("{k}:{}\n", v.trim())).collect();
    let signed_headers = headers.keys().cloned().collect::<Vec<_>>().join(";");

    let canonical_request = format!(
        "{method}\n{canonical_uri}\n{canonical_query}\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
    );
    let scope = format!("{datestamp}/{region}/{service}/aws4_request");
    let string_to_sign = format!(
        "AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}",
        sha256_hex(canonical_request.as_bytes())
    );

    let k_date = hmac(format!("AWS4{secret}").as_bytes(), datestamp.as_bytes());
    let k_region = hmac(&k_date, region.as_bytes());
    let k_service = hmac(&k_region, service.as_bytes());
    let k_signing = hmac(&k_service, b"aws4_request");
    let signature = hex::encode(hmac(&k_signing, string_to_sign.as_bytes()));

    format!(
        "AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"
    )
}

/// An S3-compatible mailbox client. Blobs are sealed before they get here; the bucket is opaque.
pub struct S3Mailbox {
    cfg: S3Config,
    http: reqwest::Client,
    host: String,
}

impl S3Mailbox {
    pub fn new(cfg: S3Config) -> Result<Self> {
        let host = cfg
            .endpoint
            .trim_start_matches("https://")
            .trim_start_matches("http://")
            .trim_end_matches('/')
            .to_string();
        Ok(Self { cfg, http: reqwest::Client::new(), host })
    }

    fn object_uri(&self, key: &str) -> String {
        // Path-style: /<bucket>/<prefix>/<key>, each path segment percent-encoded.
        let full = format!("{}/{}/{}", self.cfg.bucket, self.cfg.prefix.trim_matches('/'), key);
        let cleaned = full.split('/').filter(|s| !s.is_empty()).collect::<Vec<_>>().join("/");
        format!("/{}", utf8_percent_encode(&cleaned, ENC_PATH))
    }

    fn signed_headers(&self, method: &str, uri: &str, query: &str, payload: &[u8]) -> Vec<(String, String)> {
        let now = Utc::now();
        let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
        let datestamp = now.format("%Y%m%d").to_string();
        let payload_hash = sha256_hex(payload);

        let mut to_sign = BTreeMap::new();
        to_sign.insert("host".to_string(), self.host.clone());
        to_sign.insert("x-amz-content-sha256".to_string(), payload_hash.clone());
        to_sign.insert("x-amz-date".to_string(), amz_date.clone());

        let auth = sigv4_authorization(
            &self.cfg.access_key,
            &self.cfg.secret_key,
            &self.cfg.region,
            "s3",
            method,
            uri,
            query,
            &to_sign,
            &payload_hash,
            &amz_date,
            &datestamp,
        );
        vec![
            ("x-amz-date".to_string(), amz_date),
            ("x-amz-content-sha256".to_string(), payload_hash),
            ("authorization".to_string(), auth),
        ]
    }

    fn url(&self, uri: &str, query: &str) -> String {
        if query.is_empty() {
            format!("{}{}", self.cfg.endpoint.trim_end_matches('/'), uri)
        } else {
            format!("{}{}?{}", self.cfg.endpoint.trim_end_matches('/'), uri, query)
        }
    }

    /// Store a sealed blob under `key` (relative to the configured prefix).
    pub async fn put(&self, key: &str, data: &[u8]) -> Result<()> {
        let uri = self.object_uri(key);
        let headers = self.signed_headers("PUT", &uri, "", data);
        let mut req = self.http.put(self.url(&uri, "")).body(data.to_vec());
        for (k, v) in headers {
            req = req.header(k, v);
        }
        let resp = req.send().await.context("s3 put")?;
        if !resp.status().is_success() {
            return Err(anyhow!("s3 put {}: {}", key, resp.status()));
        }
        Ok(())
    }

    /// Fetch a sealed blob, or `None` if it doesn't exist.
    pub async fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let uri = self.object_uri(key);
        let headers = self.signed_headers("GET", &uri, "", b"");
        let mut req = self.http.get(self.url(&uri, ""));
        for (k, v) in headers {
            req = req.header(k, v);
        }
        let resp = req.send().await.context("s3 get")?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !resp.status().is_success() {
            return Err(anyhow!("s3 get {}: {}", key, resp.status()));
        }
        Ok(Some(resp.bytes().await?.to_vec()))
    }

    /// List object keys under `sub_prefix` (relative to the configured prefix). Returns keys
    /// relative to the configured prefix (so they round-trip back into `get`).
    pub async fn list(&self, sub_prefix: &str) -> Result<Vec<String>> {
        let full_prefix = {
            let p = format!("{}/{}", self.cfg.prefix.trim_matches('/'), sub_prefix.trim_matches('/'));
            p.split('/').filter(|s| !s.is_empty()).collect::<Vec<_>>().join("/")
        };
        let encoded_prefix = utf8_percent_encode(&full_prefix, ENC_QUERY).to_string();
        // ListObjectsV2 — query params must be sorted for the canonical request.
        let query = format!("list-type=2&prefix={encoded_prefix}");
        let uri = format!("/{}", utf8_percent_encode(self.cfg.bucket.trim_matches('/'), ENC_PATH));
        let headers = self.signed_headers("GET", &uri, &query, b"");
        let mut req = self.http.get(self.url(&uri, &query));
        for (k, v) in headers {
            req = req.header(k, v);
        }
        let resp = req.send().await.context("s3 list")?;
        if !resp.status().is_success() {
            return Err(anyhow!("s3 list: {}", resp.status()));
        }
        let body = resp.text().await?;
        let keys = parse_list_keys(&body);
        // Strip the configured prefix so callers get keys they can pass back to get().
        let strip = format!("{}/", self.cfg.prefix.trim_matches('/'));
        Ok(keys
            .into_iter()
            .map(|k| k.strip_prefix(&strip).map(String::from).unwrap_or(k))
            .collect())
    }
}

/// Extract `<Key>…</Key>` values from a ListObjectsV2 XML response.
fn parse_list_keys(xml: &str) -> Vec<String> {
    use quick_xml::events::Event;
    use quick_xml::Reader;
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut keys = vec![];
    // quick-xml 0.41 emits an entity ref as its own `GeneralRef` event, splitting the text
    // around it, and `BytesText::unescape()` is gone. So a key is accumulated across events
    // and flushed at `</Key>` — pushing per Text event would shatter `a&amp;b` into two keys.
    let mut cur: Option<String> = None;
    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) if e.name().as_ref() == b"Key" => cur = Some(String::new()),
            Ok(Event::End(e)) if e.name().as_ref() == b"Key" => {
                if let Some(k) = cur.take() {
                    keys.push(k);
                }
            }
            Ok(Event::Text(t)) => {
                if let (Some(k), Ok(s)) = (cur.as_mut(), t.xml10_content()) {
                    k.push_str(&s);
                }
            }
            // `&amp;` arrives as GeneralRef("amp"). Re-wrap and let quick-xml resolve it, so
            // named and numeric (`&#38;`) refs both go through the crate's own table.
            Ok(Event::GeneralRef(r)) => {
                if let (Some(k), Ok(name)) = (cur.as_mut(), r.decode()) {
                    match quick_xml::escape::unescape(&format!("&{name};")) {
                        Ok(s) => k.push_str(&s),
                        Err(_) => return keys, // malformed entity: stop, don't emit a corrupt key
                    }
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    keys
}

#[cfg(test)]
mod tests {
    use super::*;

    /// AWS SigV4 official test-suite "get-vanilla" vector — validates canonical request,
    /// string-to-sign, signing-key derivation, and the final signature end to end.
    #[test]
    fn sigv4_get_vanilla_matches_aws_vector() {
        let mut headers = BTreeMap::new();
        headers.insert("host".to_string(), "example.amazonaws.com".to_string());
        headers.insert("x-amz-date".to_string(), "20150830T123600Z".to_string());
        let empty_hash = sha256_hex(b"");
        let auth = sigv4_authorization(
            "AKIDEXAMPLE",
            "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            "us-east-1",
            "service",
            "GET",
            "/",
            "",
            &headers,
            &empty_hash,
            "20150830T123600Z",
            "20150830",
        );
        assert!(
            auth.ends_with("Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"),
            "got: {auth}"
        );
        assert!(auth.contains("SignedHeaders=host;x-amz-date"));
    }

    #[test]
    fn list_xml_parses_keys() {
        let xml = r#"<?xml version="1.0"?><ListBucketResult><Contents><Key>haven/mailbox/default/aaa</Key></Contents><Contents><Key>haven/mailbox/default/bbb</Key></Contents></ListBucketResult>"#;
        let keys = parse_list_keys(xml);
        assert_eq!(keys, vec!["haven/mailbox/default/aaa", "haven/mailbox/default/bbb"]);
    }

    /// S3 XML-escapes `&`, `<`, `>` inside `<Key>`, so the parser MUST expand entities or it
    /// hands back a key that round-trips to a 404. Pins the behaviour across the quick-xml
    /// 0.36 -> 0.41 port, where `BytesText::unescape()` split into decode + `escape::unescape`.
    #[test]
    fn list_xml_unescapes_entities_in_keys() {
        let xml = r#"<ListBucketResult><Contents><Key>haven/a&amp;b/c&lt;d&gt;e&quot;f&apos;g</Key></Contents></ListBucketResult>"#;
        assert_eq!(parse_list_keys(xml), vec![r#"haven/a&b/c<d>e"f'g"#]);
    }
}
