//! Per-circle consent to **web devices** (docs/WEB-PARITY.md, D21).
//!
//! **Withdrawn (docs/DECISIONS.md, D22 withdrawn):** the engine no longer consults these
//! positions; a linked browser is a device like any other. The records and the rule below are
//! kept so the wire is unchanged and an older app's records still parse. The web MARK (point 1)
//! is still in force: it is how a browser is shown as one.
//!
//! A browser linked to an account is a device like any other in the roster — but the code it runs
//! was delivered by a relay, so a circle's members get a say in whether their posts are shown in
//! one. Two things make that enforceable by every member's device, not just promised:
//!
//!   1. **Which devices are web devices** is a fact the ACCOUNT signs. The device credential has no
//!      spare field, and changing its signed bytes would make every shipped app reject the roster
//!      it rides in. The device NAME is inside those signed bytes, so the mark lives there: a name
//!      that starts with [`WEB_DEVICE_MARK`]. A relay cannot strip it (the credential's signature
//!      would fail), an older app simply shows it, and a mark put on a device that is not a
//!      browser only ever REMOVES access. What it cannot do: stop the primary's owner from
//!      approving a hostile page that claims to be an app — the approval screen shows the name the
//!      device gave.
//!   2. **Whether a circle allows web devices** is a set of account-signed [`CircleWebPolicy`]
//!      records, one per signer, highest version wins. Who has to say yes depends on whether the
//!      circle has a provable owner ([`web_allowed`]):
//!        * My Circle: the account it belongs to decides, alone (each device asks this of its
//!          own account, so it speaks for that account's posts only; `haven-ffi` `web_deciders`);
//!        * a creator-bound circle: its admins decide — the newest record among them;
//!        * a circle with no provable owner (an older shared circle, a direct message): EVERY member has
//!          to have said yes. Nobody can speak for it, so nobody is spoken for.
//!      No record, an unverifiable record, a tie — all mean NO. Absence is never consent.
//!
//! Enforcement is in the engine (`haven-ffi`): a web device is left out of a circle's key commits
//! and out of its key tree unless the circle allows web devices. An app that predates this ignores
//! the record and treats a web device as any other; see docs/WEB-PARITY.md for what that means.

use std::collections::{HashMap, HashSet};

use crate::identity::{HavenId, Identity};
use crate::wire::{Reader, WireTag};
use crate::{CoreError, Result};

/// The prefix of an account-signed device name that marks the device as a browser.
pub const WEB_DEVICE_MARK: &str = "🌐 ";

/// Is this (account-signed) device name marked as a web device?
pub fn is_web_device_name(name: &str) -> bool {
    name.starts_with(WEB_DEVICE_MARK)
}

/// `name` with the web mark (idempotent). An empty name becomes just the mark and a generic word,
/// so a marked name is never empty in a device list.
pub fn mark_web_device_name(name: &str) -> String {
    if is_web_device_name(name) {
        return name.to_string();
    }
    let name = name.trim();
    if name.is_empty() {
        format!("{WEB_DEVICE_MARK}Browser")
    } else {
        format!("{WEB_DEVICE_MARK}{name}")
    }
}

const POLICY_DOMAIN: &[u8] = b"haven-circle-web-policy-v1";

const WIRE: WireTag = WireTag::new(
    "web policy: unexpected end of input",
    "web policy: length overflow",
    "web policy: invalid utf-8",
);

/// "Account `signer` says web devices are (not) allowed in circle `circle_id`, as of `version`."
/// Signed by the signer's ACCOUNT key, so only a device that holds the account seed can make one —
/// a web device can never vote itself in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CircleWebPolicy {
    /// The circle this applies to (its id bytes).
    pub circle_id: Vec<u8>,
    /// The account stating its position.
    pub signer: [u8; 32],
    /// Web devices allowed?
    pub allow: bool,
    /// Monotonic per (circle, signer) — higher wins, so a change of mind supersedes and an old
    /// "yes" cannot be replayed over a newer "no".
    pub version: u64,
    /// Hybrid signature by the signer's account identity over [`Self::signing_bytes`].
    pub sig: Vec<u8>,
}

impl CircleWebPolicy {
    fn signing_bytes(circle_id: &[u8], signer: &[u8; 32], allow: bool, version: u64) -> Vec<u8> {
        let mut v = Vec::with_capacity(POLICY_DOMAIN.len() + 4 + circle_id.len() + 32 + 1 + 8);
        v.extend_from_slice(POLICY_DOMAIN);
        v.extend_from_slice(&(circle_id.len() as u32).to_le_bytes());
        v.extend_from_slice(circle_id);
        v.extend_from_slice(signer);
        v.push(allow as u8);
        v.extend_from_slice(&version.to_le_bytes());
        v
    }

    /// Sign a position under `account`.
    pub fn issue(account: &Identity, circle_id: &[u8], allow: bool, version: u64) -> Self {
        let signer = account.public().node_id_bytes();
        let sig = account.sign(&Self::signing_bytes(circle_id, &signer, allow, version));
        Self { circle_id: circle_id.to_vec(), signer, allow, version, sig }
    }

    /// Verify against the signer's pinned account bundle (id match + hybrid signature).
    pub fn verify(&self, signer_pub: &HavenId) -> Result<()> {
        if signer_pub.node_id_bytes() != self.signer {
            return Err(CoreError::Crypto("web policy: signer id mismatch"));
        }
        signer_pub.verify(&Self::signing_bytes(&self.circle_id, &self.signer, self.allow, self.version), &self.sig)
    }

    /// Wire: `lp(circle_id) ‖ signer(32) ‖ allow(1) ‖ version(8) ‖ sig`.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(4 + self.circle_id.len() + 32 + 1 + 8 + self.sig.len());
        v.extend_from_slice(&(self.circle_id.len() as u32).to_le_bytes());
        v.extend_from_slice(&self.circle_id);
        v.extend_from_slice(&self.signer);
        v.push(self.allow as u8);
        v.extend_from_slice(&self.version.to_le_bytes());
        v.extend_from_slice(&self.sig);
        v
    }

    /// Inverse of [`Self::to_bytes`]. The flag byte must be exactly 0 or 1.
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        let mut r = Reader::new(b, WIRE);
        let circle_id = r.bytes_lp()?.to_vec();
        let signer = r.array32()?;
        let allow = match r.u8()? {
            0 => false,
            1 => true,
            _ => return Err(CoreError::Encoding("web policy: bad flag")),
        };
        let version = r.u64()?;
        let sig = r.rest().to_vec();
        if sig.is_empty() {
            return Err(CoreError::Encoding("web policy: missing signature"));
        }
        Ok(Self { circle_id, signer, allow, version, sig })
    }
}

/// Each signer's CURRENT position: the highest-version record per signer. Two records by one
/// signer at the same version that disagree count as NO (a signer who says both has not said yes).
/// The caller passes only records it has verified, for the circle in question.
pub fn current_positions(records: &[CircleWebPolicy]) -> HashMap<[u8; 32], bool> {
    let mut best: HashMap<[u8; 32], (u64, bool)> = HashMap::new();
    for r in records {
        match best.get_mut(&r.signer) {
            Some((v, allow)) => {
                if r.version > *v {
                    *v = r.version;
                    *allow = r.allow;
                } else if r.version == *v && r.allow != *allow {
                    *allow = false;
                }
            }
            None => {
                best.insert(r.signer, (r.version, r.allow));
            }
        }
    }
    best.into_iter().map(|(k, (_, allow))| (k, allow)).collect()
}

/// Does this circle allow web devices?
///
/// * `admins = Some(set)` — a creator-bound circle: yes iff the newest record signed by one of its
///   admins says yes. With no record from an admin, or two admins' newest records tied at one
///   version and disagreeing, no. A record from someone who is not an admin counts for nothing.
/// * `admins = None` — no provable owner: yes iff EVERY account in `members` (which must include
///   the caller's own) currently says yes. An empty member list is no.
pub fn web_allowed(admins: Option<&HashSet<[u8; 32]>>, members: &[[u8; 32]], records: &[CircleWebPolicy]) -> bool {
    match admins {
        Some(admins) => {
            let mut newest: Option<(u64, bool)> = None;
            for r in records.iter().filter(|r| admins.contains(&r.signer)) {
                newest = Some(match newest {
                    Some((v, _)) if r.version > v => (r.version, r.allow),
                    Some((v, allow)) if r.version == v => (v, allow && r.allow),
                    Some(keep) => keep,
                    None => (r.version, r.allow),
                });
            }
            newest.is_some_and(|(_, allow)| allow)
        }
        None => {
            if members.is_empty() {
                return false;
            }
            let positions = current_positions(records);
            members.iter().all(|m| positions.get(m).copied().unwrap_or(false))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn acct(b: u8) -> Identity {
        Identity::from_seed(&[b; 32])
    }
    fn id(b: u8) -> [u8; 32] {
        acct(b).public().node_id_bytes()
    }
    const C: &[u8] = b"c1circle";

    #[test]
    fn the_mark_is_a_prefix_and_marking_is_idempotent() {
        assert!(!is_web_device_name("Blaine's iPhone"));
        assert!(!is_web_device_name(""));
        assert!(!is_web_device_name("Browser 🌐 "), "only a PREFIX is the mark");
        let m = mark_web_device_name("Chrome on a Mac");
        assert_eq!(m, "🌐 Chrome on a Mac");
        assert!(is_web_device_name(&m));
        assert_eq!(mark_web_device_name(&m), m);
        assert_eq!(mark_web_device_name("   "), "🌐 Browser");
    }

    #[test]
    fn a_policy_round_trips_and_verifies_only_for_its_signer_and_content() {
        let a = acct(1);
        let p = CircleWebPolicy::issue(&a, C, true, 3);
        assert_eq!(CircleWebPolicy::from_bytes(&p.to_bytes()).unwrap(), p);
        p.verify(&a.public()).unwrap();
        assert!(p.verify(&acct(2).public()).is_err(), "another account's key");

        // Every field is under the signature.
        let mut q = p.clone();
        q.allow = false;
        assert!(q.verify(&a.public()).is_err(), "flipped answer");
        let mut q = p.clone();
        q.version = 4;
        assert!(q.verify(&a.public()).is_err(), "bumped version");
        let mut q = p.clone();
        q.circle_id = b"c1other".to_vec();
        assert!(q.verify(&a.public()).is_err(), "moved to another circle");
    }

    #[test]
    fn malformed_policies_are_refused() {
        let p = CircleWebPolicy::issue(&acct(1), C, true, 1).to_bytes();
        for n in 0..(4 + C.len() + 32 + 1 + 8 + 1) {
            assert!(CircleWebPolicy::from_bytes(&p[..n]).is_err(), "truncated at {n}");
        }
        let mut bad = p.clone();
        bad[4 + C.len() + 32] = 2;
        assert!(CircleWebPolicy::from_bytes(&bad).is_err(), "a flag that is neither yes nor no");
    }

    #[test]
    fn an_owned_circle_follows_its_admins_newest_word() {
        let admins: HashSet<[u8; 32]> = [id(1), id(2)].into_iter().collect();
        let members = [id(1), id(2), id(3)];
        let yes = |who: u8, v: u64| CircleWebPolicy::issue(&acct(who), C, true, v);
        let no = |who: u8, v: u64| CircleWebPolicy::issue(&acct(who), C, false, v);

        assert!(!web_allowed(Some(&admins), &members, &[]), "silence is no");
        assert!(!web_allowed(Some(&admins), &members, &[yes(3, 9)]), "a member who is not an admin decides nothing");
        assert!(web_allowed(Some(&admins), &members, &[yes(1, 1)]));
        assert!(!web_allowed(Some(&admins), &members, &[yes(1, 1), no(2, 2)]), "a newer no wins");
        assert!(web_allowed(Some(&admins), &members, &[yes(1, 3), no(2, 2)]), "a newer yes wins");
        assert!(!web_allowed(Some(&admins), &members, &[yes(1, 2), no(2, 2)]), "a tie is no");
        assert!(!web_allowed(Some(&admins), &members, &[yes(1, 1), no(1, 2)]), "an admin changed their mind");
    }

    #[test]
    fn a_circle_with_no_owner_needs_every_member() {
        let members = [id(1), id(2), id(3)];
        let yes = |who: u8, v: u64| CircleWebPolicy::issue(&acct(who), C, true, v);
        let no = |who: u8, v: u64| CircleWebPolicy::issue(&acct(who), C, false, v);

        assert!(!web_allowed(None, &members, &[]));
        assert!(!web_allowed(None, &members, &[yes(1, 1), yes(2, 1)]), "one member has not answered");
        assert!(web_allowed(None, &members, &[yes(1, 1), yes(2, 1), yes(3, 1)]));
        assert!(!web_allowed(None, &members, &[yes(1, 1), yes(2, 1), yes(3, 1), no(2, 2)]), "one member withdrew");
        assert!(!web_allowed(None, &members, &[yes(1, 5), yes(2, 1), yes(3, 1), no(1, 5)]), "yes and no at one version is no");
        // An outsider's yes neither helps nor is needed.
        assert!(web_allowed(None, &members, &[yes(1, 1), yes(2, 1), yes(3, 1), no(9, 4)]));
        assert!(!web_allowed(None, &[], &[yes(1, 1)]), "no members, no consent");
        // A newly added member has to agree too.
        assert!(!web_allowed(None, &[id(1), id(2), id(3), id(4)], &[yes(1, 1), yes(2, 1), yes(3, 1)]));
    }
}
