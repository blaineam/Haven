//! Rotatable self-sync key state (Switch-Flip 1.0.7 §6 / audit M1) for the desktop backend.
//!
//! `docs/SWITCH-FLIP-1.0.7.md` §6: once the retirement switch is ON **and** every one of the
//! account's own devices is seed-drop-capable, the account-state self-sync channel must rotate its
//! key on **every device revocation** — otherwise a revoked (seedless) device keeps reading and
//! LWW-writing the owner's account state forever. This module is the PRIMARY's device-local record
//! of the currently-honored rotated key + its epoch, persisted 0600 (the key is seed-grade). It is
//! NEVER synced; the rotated key reaches still-authorized devices as an account-signed
//! `seal_self_sync_key_epoch_grant` envelope (distributed by the engine over the self-sync mailbox).
//!
//! Reading is dual-key ([`haven_p2p::selfsync::AccountState::open_any`]): a v1 blob is accepted only
//! at the epoch we currently honor (a revoked device's stale-epoch write is refused), and the v0
//! seed-derived key is passed alongside during the transition window, then dropped (`None`) once the
//! account is fully retired — which completes the revocation cut.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::store::Paths;

/// The PRIMARY's rotated self-sync key state. `epoch == 0` (the default) means the channel has never
/// rotated — the account is still on the v0 seed-derived path and every byte on the wire is
/// byte-identical to 1.0.6.
#[derive(Default, Clone, Serialize, Deserialize)]
pub struct SelfSyncRotation {
    /// The current key-epoch. 0 = never rotated (v0 only). Bumped by one on each revocation-rotation.
    pub epoch: u64,
    /// The current 32-byte rotated key (from the OS CSPRNG). Empty until the first rotation.
    pub key: Vec<u8>,
}

impl SelfSyncRotation {
    fn file(paths: &Paths) -> PathBuf {
        paths.root.join("selfsync-rotation.json")
    }

    pub fn load(paths: &Paths) -> Self {
        std::fs::read(Self::file(paths))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, paths: &Paths) -> std::io::Result<()> {
        let _ = std::fs::create_dir_all(&paths.root);
        let file = Self::file(paths);
        std::fs::write(&file, serde_json::to_vec(self).unwrap_or_default())?;
        // 0600 — the rotated key is seed-grade; guard it like the account seed / the seedless grant.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600));
        }
        Ok(())
    }

    /// The current rotated key as a fixed array, or `None` while never-rotated / malformed.
    pub fn key32(&self) -> Option<[u8; 32]> {
        if self.epoch == 0 || self.key.len() != 32 {
            return None;
        }
        let mut k = [0u8; 32];
        k.copy_from_slice(&self.key);
        Some(k)
    }

    /// The reader's accepted `(epoch → key)` map for [`haven_p2p::selfsync::AccountState::open_any`].
    /// Just the current epoch (a stale-epoch write from a revoked device is refused). Empty when
    /// never rotated.
    pub fn accepted(&self) -> BTreeMap<u64, [u8; 32]> {
        let mut m = BTreeMap::new();
        if let Some(k) = self.key32() {
            m.insert(self.epoch, k);
        }
        m
    }

    /// True once the channel has rotated at least once (the v1 path is in effect).
    pub fn rotated(&self) -> bool {
        self.key32().is_some()
    }

    /// Advance to a fresh epoch under a newly-minted key (called on a device revocation).
    pub fn rotate_to(&mut self, key: [u8; 32]) {
        self.epoch = self.epoch.saturating_add(1);
        self.key = key.to_vec();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_paths(tag: &str) -> Paths {
        let dir = std::env::temp_dir().join(format!(
            "haven-ssrot-test-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Paths { base: dir.clone(), root: dir }
    }

    #[test]
    fn default_is_v0_never_rotated() {
        let r = SelfSyncRotation::default();
        assert_eq!(r.epoch, 0);
        assert!(!r.rotated());
        assert!(r.key32().is_none());
        assert!(r.accepted().is_empty(), "a never-rotated reader accepts no v1 epoch");
    }

    #[test]
    fn rotate_bumps_epoch_and_exposes_accepted_key() {
        let mut r = SelfSyncRotation::default();
        r.rotate_to([7u8; 32]);
        assert_eq!(r.epoch, 1);
        assert!(r.rotated());
        assert_eq!(r.key32(), Some([7u8; 32]));
        let acc = r.accepted();
        assert_eq!(acc.len(), 1);
        assert_eq!(acc.get(&1), Some(&[7u8; 32]));

        // Second revocation bumps again and the OLD epoch is no longer accepted (revoked-device cut).
        r.rotate_to([9u8; 32]);
        assert_eq!(r.epoch, 2);
        let acc = r.accepted();
        assert_eq!(acc.get(&2), Some(&[9u8; 32]));
        assert!(acc.get(&1).is_none(), "a stale (pre-revocation) epoch is refused");
    }

    #[test]
    fn round_trips_through_disk() {
        let paths = tmp_paths("rt");
        assert!(!SelfSyncRotation::load(&paths).rotated());
        let mut r = SelfSyncRotation::default();
        r.rotate_to([3u8; 32]);
        r.save(&paths).unwrap();
        let loaded = SelfSyncRotation::load(&paths);
        assert_eq!(loaded.epoch, 1);
        assert_eq!(loaded.key32(), Some([3u8; 32]));
        let _ = std::fs::remove_dir_all(&paths.root);
    }

    #[cfg(unix)]
    #[test]
    fn file_is_0600() {
        use std::os::unix::fs::PermissionsExt;
        let paths = tmp_paths("perm");
        let mut r = SelfSyncRotation::default();
        r.rotate_to([1u8; 32]);
        r.save(&paths).unwrap();
        let mode = std::fs::metadata(SelfSyncRotation::file(&paths)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "selfsync-rotation.json must be 0600");
        let _ = std::fs::remove_dir_all(&paths.root);
    }
}
