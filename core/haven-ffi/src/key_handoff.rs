//! Key hand-off between the devices of ONE account.
//!
//! Every author seals their posts to the devices they know of. A device linked today is known to
//! nobody but its own account, so it used to show its own account's posts and nothing else until
//! each contact's app happened to come online, learn the new roster and re-seal for it: hours or
//! days, and never from a contact whose app is not opened. The devices that were already on the
//! account hold the keys the whole time.
//!
//! So they hand them over. [`HavenSocial::export_key_handoff`] seals, to ONE named device of my own
//! account, the content keys this device holds for every circle (other authors' epoch keys, my
//! own, the retained alternates, and the circle secrets that locate media).
//! [`HavenSocial::import_key_handoff`] opens such a blob and merges it by the same rule a key
//! commit is merged by, then re-opens what was parked for want of a key.
//!
//! What makes this safe to accept:
//!   * the blob is sealed to the receiving device's own bundle, so nobody else can read it;
//!   * it is signed by the sending device, and it is accepted only when that device is an
//!     AUTHORIZED device of MY OWN account in the roster I hold (account-signed, verified). A
//!     contact, a stranger, or a device the account has removed cannot hand me anything;
//!   * the target named at export must likewise be an authorized device of the account, so a
//!     device cannot be talked into exporting its keys to an outsider.
//!
//! What it does NOT do: reach further back than the keys still held. Old keys are deleted on a
//! schedule (`prune_epoch_keys`), and history older than that arrives when its author re-seals it,
//! as before. And it changes nothing about who can read a circle: a device the account approved
//! receives what the account's other devices can already read.

use super::*;

/// Envelope group label (domain separation from every other sealed-to-device blob).
const KEY_HANDOFF_GROUP: &str = "haven-key-handoff-v1";
const VERSION: u8 = 1;
/// Refuse absurd blobs before allocating for them.
const MAX_KEYS: u32 = 200_000;

fn put_str(out: &mut Vec<u8>, s: &str) {
    out.extend_from_slice(&(s.len() as u32).to_be_bytes());
    out.extend_from_slice(s.as_bytes());
}

struct Cur<'a>(&'a [u8]);
impl Cur<'_> {
    fn take(&mut self, n: usize) -> Option<&[u8]> {
        if self.0.len() < n {
            return None;
        }
        let (a, b) = self.0.split_at(n);
        self.0 = b;
        Some(a)
    }
    fn u8(&mut self) -> Option<u8> {
        self.take(1).map(|b| b[0])
    }
    fn u32(&mut self) -> Option<u32> {
        self.take(4).map(|b| u32::from_be_bytes(b.try_into().unwrap()))
    }
    fn u64(&mut self) -> Option<u64> {
        self.take(8).map(|b| u64::from_be_bytes(b.try_into().unwrap()))
    }
    fn key(&mut self) -> Option<[u8; 32]> {
        self.take(32).map(|b| b.try_into().unwrap())
    }
    fn str(&mut self) -> Option<String> {
        let n = self.u32()? as usize;
        if n > 4096 {
            return None;
        }
        String::from_utf8(self.take(n)?.to_vec()).ok()
    }
}

/// One circle's keys as carried in a hand-off.
#[derive(Default, PartialEq, Debug)]
struct CircleKeys {
    id: String,
    /// (epoch, key, is_alternate)
    mine: Vec<(u64, [u8; 32], bool)>,
    /// (author account hex, epoch, key, is_alternate)
    peers: Vec<(String, u64, [u8; 32], bool)>,
    /// (author account hex, circle secret)
    secrets: Vec<(String, [u8; 32])>,
}

fn encode(circles: &[CircleKeys]) -> Vec<u8> {
    let mut out = vec![VERSION];
    out.extend_from_slice(&(circles.len() as u32).to_be_bytes());
    for c in circles {
        put_str(&mut out, &c.id);
        out.extend_from_slice(&(c.mine.len() as u32).to_be_bytes());
        for (epoch, key, alt) in &c.mine {
            out.extend_from_slice(&epoch.to_be_bytes());
            out.extend_from_slice(key);
            out.push(*alt as u8);
        }
        out.extend_from_slice(&(c.peers.len() as u32).to_be_bytes());
        for (author, epoch, key, alt) in &c.peers {
            put_str(&mut out, author);
            out.extend_from_slice(&epoch.to_be_bytes());
            out.extend_from_slice(key);
            out.push(*alt as u8);
        }
        out.extend_from_slice(&(c.secrets.len() as u32).to_be_bytes());
        for (author, secret) in &c.secrets {
            put_str(&mut out, author);
            out.extend_from_slice(secret);
        }
    }
    out
}

fn decode(bytes: &[u8]) -> Option<Vec<CircleKeys>> {
    let mut r = Cur(bytes);
    if r.u8()? != VERSION {
        return None;
    }
    let n = r.u32()?;
    if n > 100_000 {
        return None;
    }
    let mut out = Vec::new();
    for _ in 0..n {
        let mut c = CircleKeys { id: r.str()?, ..Default::default() };
        let m = r.u32()?;
        if m > MAX_KEYS {
            return None;
        }
        for _ in 0..m {
            c.mine.push((r.u64()?, r.key()?, r.u8()? != 0));
        }
        let p = r.u32()?;
        if p > MAX_KEYS {
            return None;
        }
        for _ in 0..p {
            c.peers.push((r.str()?, r.u64()?, r.key()?, r.u8()? != 0));
        }
        let s = r.u32()?;
        if s > MAX_KEYS {
            return None;
        }
        for _ in 0..s {
            c.secrets.push((r.str()?, r.key()?));
        }
        out.push(c);
    }
    r.0.is_empty().then_some(out)
}

/// The public bundle of one of my own account's AUTHORIZED devices, by the account-signed roster
/// I hold; `None` for anything else. A primary that never took a device identity of its own is
/// its account id (the roster's bare account leaf, while the roster still authorizes it).
fn my_device_bundle_of(st: &NetState, device_id: &[u8; 32]) -> Option<HavenId> {
    let acct = st.me().node_id_bytes();
    let cd = st.device_lists.get(&acct)?;
    if !cd.list.is_authorized(device_id) {
        return None;
    }
    if *device_id == acct {
        return Some(st.me().clone());
    }
    cd.credentials.iter().find(|c| c.device_id() == *device_id).map(|c| c.device.clone())
}

fn collect(st: &NetState) -> Vec<CircleKeys> {
    st.circles
        .iter()
        .map(|c| {
            let mut k = CircleKeys { id: c.id.clone(), ..Default::default() };
            for (e, key) in &c.my_epoch_keys {
                k.mine.push((*e, *key, false));
            }
            for (e, alts) in &c.my_epoch_keys_alt {
                k.mine.extend(alts.iter().map(|key| (*e, *key, true)));
            }
            for ((author, e), key) in &c.peer_epoch_keys {
                k.peers.push((author.clone(), *e, *key, false));
            }
            for ((author, e), alts) in &c.peer_epoch_keys_alt {
                k.peers.extend(alts.iter().map(|key| (author.clone(), *e, *key, true)));
            }
            for (author, secret) in &c.peer_circle_secrets {
                k.secrets.push((author.clone(), *secret));
            }
            // Stable order: the same state always seals the same plaintext.
            k.mine.sort();
            k.peers.sort();
            k.secrets.sort();
            k
        })
        .filter(|k| !(k.mine.is_empty() && k.peers.is_empty() && k.secrets.is_empty()))
        .collect()
}

/// Merge one circle's handed-over keys. Returns how many slots changed.
fn merge(c: &mut Circle, me_hex: &str, keys: CircleKeys) -> u32 {
    let mut changed = 0u32;
    for (epoch, key, _alt) in keys.mine {
        let mut primary = c.my_epoch_keys.get(&epoch).copied();
        let alts = c.my_epoch_keys_alt.entry(epoch).or_default();
        if converge_epoch_key(&mut primary, alts, key) {
            changed += 1;
        }
        if let Some(k) = primary {
            c.my_epoch_keys.insert(epoch, k);
        }
    }
    for (author, epoch, key, _alt) in keys.peers {
        if author.len() != 64 || author == me_hex {
            continue;
        }
        let slot = (author, epoch);
        let mut primary = c.peer_epoch_keys.get(&slot).copied();
        let alts = c.peer_epoch_keys_alt.entry(slot.clone()).or_default();
        if converge_epoch_key(&mut primary, alts, key) {
            changed += 1;
        }
        if let Some(k) = primary {
            c.peer_epoch_keys.insert(slot, k);
        }
    }
    for (author, secret) in keys.secrets {
        if author.len() != 64 || secret == [0u8; 32] {
            continue;
        }
        match c.peer_circle_secrets.get(&author) {
            Some(cur) if *cur >= secret => {}
            _ => {
                c.peer_circle_secrets.insert(author, secret);
                changed += 1;
            }
        }
    }
    // Empty alternate lists were created by `entry().or_default()` above; do not keep them.
    c.my_epoch_keys_alt.retain(|_, v| !v.is_empty());
    c.peer_epoch_keys_alt.retain(|_, v| !v.is_empty());
    changed
}

#[uniffi::export]
impl HavenSocial {
    /// Seal the content keys this device holds to ANOTHER device of my own account (64-hex device
    /// id). Empty when that device is not an authorized device of my account, is this device, or
    /// there is nothing to hand over. See the module docs.
    pub fn export_key_handoff(&self, target_device_hex: String) -> Vec<u8> {
        let st = self.state.lock().unwrap();
        let Ok(target) = decode_hex32(&target_device_hex) else { return vec![] };
        let signer = match &st.device {
            Some(d) => Identity::from_seed(&d.secret_seed()),
            None => Identity::from_seed(&st.account_or_device_signer().secret_seed()),
        };
        if target == signer.public().node_id_bytes() {
            return vec![];
        }
        let Some(bundle) = my_device_bundle_of(&st, &target) else { return vec![] };
        let circles = collect(&st);
        if circles.is_empty() {
            return vec![];
        }
        let group = Group::new(KEY_HANDOFF_GROUP, vec![bundle]);
        seal_bytes(&signer, &group, &encode(&circles)).map(|e| e.to_bytes()).unwrap_or_default()
    }

    /// Open a hand-off another device of my own account sealed to this one, and merge its keys.
    /// Returns the ids of the circles that gained a key (empty: refused, or nothing new). A blob
    /// from a device that is not an authorized device of my account is refused.
    pub fn import_key_handoff(&self, blob: Vec<u8>) -> Vec<String> {
        let mut st = self.state.lock().unwrap();
        let Ok(env) = haven_p2p::social::SealedEnvelope::from_bytes(&blob) else { return vec![] };
        let Ok(sender) = decode_hex32(&env.sender_hex()) else { return vec![] };
        let Some(sender_bundle) = my_device_bundle_of(&st, &sender) else { return vec![] };
        let opener = match &st.device {
            Some(d) => Identity::from_seed(&d.secret_seed()),
            None => Identity::from_seed(&st.account_or_device_signer().secret_seed()),
        };
        let Ok(plain) = haven_p2p::social::open_bytes(&opener, &sender_bundle, &env) else { return vec![] };
        let Some(circles) = decode(&plain) else { return vec![] };
        let me_hex = hex(&st.me().node_id_bytes());
        let mut gained = Vec::new();
        for keys in circles {
            let Some(idx) = st.circles.iter().position(|c| c.id == keys.id) else { continue };
            let id = keys.id.clone();
            if merge(&mut st.circles[idx], &me_hex, keys) > 0 {
                st.circles[idx].prune_epoch_keys();
                drain_pending(&mut st, idx); // what was parked for want of a key may open now
                gained.push(id);
            }
        }
        gained
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_wire_form_round_trips_and_refuses_what_is_not_one() {
        let c = CircleKeys {
            id: "default".into(),
            mine: vec![(1, [1; 32], false), (1, [2; 32], true)],
            peers: vec![("ab".repeat(32), 7, [3; 32], false)],
            secrets: vec![("cd".repeat(32), [4; 32])],
        };
        let bytes = encode(&[c]);
        let back = decode(&bytes).unwrap();
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].peers[0].1, 7);
        assert_eq!(encode(&back), bytes);
        assert!(decode(&bytes[..bytes.len() - 1]).is_none(), "truncated");
        let mut longer = bytes.clone();
        longer.push(0);
        assert!(decode(&longer).is_none(), "trailing bytes");
        let mut wrong = bytes.clone();
        wrong[0] = 9;
        assert!(decode(&wrong).is_none(), "another version");
        assert!(decode(&[]).is_none());
    }
}
