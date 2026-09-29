//! Release signatures for `haven-relay` binaries.
//!
//! Every relay asset a release publishes (`haven-relay-<target>[.exe]`) ships with a detached
//! `<asset>.sig` text file. The signature is an Ed25519 signature — by one of the
//! [`TRUSTED_KEYS`] compiled into the relay — over a domain-separated message binding THREE
//! things together:
//!
//! * the SHA-256 of the asset bytes (so a tampered binary fails),
//! * the asset NAME (so a validly-signed binary for another target — or a `.sig` copied next to a
//!   different file — can't be swapped in: cross-asset replay),
//! * the release VERSION (so an old, validly-signed, possibly-vulnerable binary can't be served as
//!   "the new release": version replay / downgrade).
//!
//! The verifier rebuilds that message from what IT expects (the version it chose, the asset name
//! for its own target, the hash it computed) — never from the fields printed inside the `.sig` —
//! so the printed fields are informational and a mismatch is simply a verification failure.
//!
//! This file is shared VERBATIM with the tiny `haven-relay-sign` CI tool (`#[path]`-included), so
//! the signer and the verifier can never disagree about the message format. Keep it
//! dependency-light: `ed25519-dalek`, `sha2`, `std`.

use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};

/// Public keys whose signatures the updater accepts, as 64-hex Ed25519 public keys.
///
/// ROTATION: add the new key here and ship a release signed with the OLD key (so every running
/// relay learns the new key through a trusted update), then switch the CI secret to the new key,
/// then — a release or two later — drop the old key from this list. A leaked key is revoked by
/// removing it and shipping a release signed by a remaining key; relays that already trust only
/// the leaked key would need a manual reinstall, which is why the list should normally hold a
/// spare offline key as well.
pub const TRUSTED_KEYS: &[&str] = &[
    // Primary release key, id 8e0c7035121bbb41 (generated 2026-09-29; private seed lives only in the RELAY_SIGNING_KEY
    // GitHub Actions secret + the owner's offline backup).
    "d8bc33972be5ce11151f40b0ad50edcd967047b91faccbcd64faf9ffb738943d",
];

/// First line of every `.sig` file (format version).
pub const SIG_MAGIC: &str = "haven-relay-sig v1";

/// Domain-separation prefix of the signed message. Changing it invalidates every signature.
const DOMAIN: &[u8] = b"haven-relay/release-signature/v1\0";

/// Lowercase hex.
pub fn to_hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Parse lowercase/uppercase hex of an exact length.
pub fn from_hex(s: &str, len: usize) -> Option<Vec<u8>> {
    let s = s.trim();
    if s.len() != len * 2 || !s.is_ascii() {
        return None;
    }
    (0..len).map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()).collect()
}

/// SHA-256 of `bytes`.
pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

/// Short key id: the first 8 bytes of SHA-256(public key), hex. Printed in `.sig` files and
/// logs so an operator can tell which key signed a release without printing the key itself.
pub fn key_id(pubkey: &[u8; 32]) -> String {
    to_hex(&sha256(pubkey)[..8])
}

/// The exact bytes that get signed.
pub fn signed_message(version: &str, asset: &str, sha256: &[u8; 32]) -> Vec<u8> {
    let mut m = Vec::with_capacity(DOMAIN.len() + version.len() + asset.len() + 34);
    m.extend_from_slice(DOMAIN);
    m.extend_from_slice(version.as_bytes());
    m.push(0);
    m.extend_from_slice(asset.as_bytes());
    m.push(0);
    m.extend_from_slice(sha256);
    m
}

/// Sign an asset: returns the full `.sig` file contents. (Used by the `haven-relay-sign` CI tool,
/// which compiles this file too, and by tests — the relay itself only verifies.)
#[allow(dead_code)]
pub fn sign_asset(seed: &[u8; 32], version: &str, asset: &str, bytes: &[u8]) -> String {
    let sk = SigningKey::from_bytes(seed);
    let digest = sha256(bytes);
    let sig = sk.sign(&signed_message(version, asset, &digest));
    let pk = sk.verifying_key().to_bytes();
    format!(
        "{SIG_MAGIC}\nversion {version}\nasset {asset}\nsha256 {}\nkey {}\nsig {}\n",
        to_hex(&digest),
        key_id(&pk),
        to_hex(&sig.to_bytes())
    )
}

/// The public key for a 32-byte seed.
#[allow(dead_code)]
pub fn public_key(seed: &[u8; 32]) -> [u8; 32] {
    SigningKey::from_bytes(seed).verifying_key().to_bytes()
}

/// Parsed `.sig` file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SigFile {
    pub version: String,
    pub asset: String,
    pub sha256: [u8; 32],
    pub key_id: String,
    pub sig: [u8; 64],
}

/// Parse a `.sig` file. Strict: magic line first, every field exactly once.
pub fn parse_sig(text: &str) -> Result<SigFile, String> {
    let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty());
    if lines.next() != Some(SIG_MAGIC) {
        return Err("not a haven-relay v1 signature file".into());
    }
    let (mut version, mut asset, mut sha, mut kid, mut sig) = (None, None, None, None, None);
    for line in lines {
        let (k, v) = line.split_once(' ').ok_or("malformed signature line")?;
        let slot = match k {
            "version" => &mut version,
            "asset" => &mut asset,
            "sha256" => &mut sha,
            "key" => &mut kid,
            "sig" => &mut sig,
            _ => return Err(format!("unknown signature field '{k}'")),
        };
        if slot.replace(v.trim().to_string()).is_some() {
            return Err(format!("duplicate signature field '{k}'"));
        }
    }
    let sha = from_hex(&sha.ok_or("missing sha256")?, 32).ok_or("bad sha256")?;
    let sigb = from_hex(&sig.ok_or("missing sig")?, 64).ok_or("bad sig")?;
    Ok(SigFile {
        version: version.ok_or("missing version")?,
        asset: asset.ok_or("missing asset")?,
        sha256: sha.try_into().map_err(|_| "bad sha256")?,
        key_id: kid.ok_or("missing key")?,
        sig: sigb.try_into().map_err(|_| "bad sig")?,
    })
}

/// Decode the compiled-in [`TRUSTED_KEYS`].
pub fn trusted_keys() -> Vec<[u8; 32]> {
    TRUSTED_KEYS
        .iter()
        .filter_map(|h| from_hex(h, 32))
        .filter_map(|v| v.try_into().ok())
        .collect()
}

/// Verify `sig_text` for the asset `expected_asset` of release `expected_version`, whose bytes
/// hash to `actual_sha256`, against `keys`. Returns the key id that verified.
///
/// The message is rebuilt from the EXPECTED values, so a signature made for another asset name,
/// another version or other bytes can never verify — whatever the `.sig` text claims.
pub fn verify(
    sig_text: &str,
    expected_version: &str,
    expected_asset: &str,
    actual_sha256: &[u8; 32],
    keys: &[[u8; 32]],
) -> Result<String, String> {
    let sf = parse_sig(sig_text)?;
    // Cheap, clear refusals first (the signature check below would fail anyway).
    if sf.version != expected_version {
        return Err(format!("signature is for version {}, expected {expected_version}", sf.version));
    }
    if sf.asset != expected_asset {
        return Err(format!("signature is for asset {}, expected {expected_asset}", sf.asset));
    }
    if &sf.sha256 != actual_sha256 {
        return Err("downloaded file does not match the signed SHA-256".into());
    }
    let msg = signed_message(expected_version, expected_asset, actual_sha256);
    let sig = Signature::from_bytes(&sf.sig);
    for k in keys {
        let Ok(vk) = VerifyingKey::from_bytes(k) else { continue };
        if vk.verify_strict(&msg, &sig).is_ok() {
            return Ok(key_id(k));
        }
    }
    // Unknown key, forged signature, or a signature over different (version, asset, hash) than
    // the printed fields claim — all the same answer.
    Err("signature does not verify against any trusted release key".into())
}
