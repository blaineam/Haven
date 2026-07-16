//! Transport seam: the path-selector that keeps traffic off the relay whenever
//! a closer, cheaper path exists.
//!
//! Priority ladder (reachability first, then bandwidth):
//!   1. **Bluetooth (BLE)** — always-on presence + small payloads / control msgs,
//!      works with zero network. Low bandwidth, so not for bulk.
//!   2. **Local WiFi / peer-to-peer WiFi** — same LAN or router-less AWDL-style
//!      direct link. Hundreds of Mbps; this carries the big files.
//!   3. **Relay** — last resort when no local path exists. Carries only opaque
//!      encrypted blobs (it never holds plaintext or PII).
//!
//! The selector *races* the available paths (Happy-Eyeballs style), prefers the
//! cheapest/fastest that's actually up, and may upgrade mid-transfer (e.g. start on
//! BLE, switch to WiFi once it negotiates).
//!
//! This module is the trait-only seam. Concrete impls land next:
//!   * `IrohTransport`  — covers rungs 2 & 3 (LAN discovery + relay fallback).
//!   * `BleTransport`   — covers rung 1 (CoreBluetooth on Apple).
//! Both feed the same [`Transport`] interface so the selector treats them uniformly.

use std::fmt;

/// A physical path to a peer, ordered cheapest/most-private first.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Path {
    /// Bluetooth LE — local, zero-network, low-bandwidth.
    Bluetooth,
    /// Local or peer-to-peer WiFi — local, high-bandwidth.
    LocalWifi,
    /// Relay network — non-local, last resort, encrypted blobs only.
    Relay,
}

impl Path {
    /// Rough rank used by the selector; lower = preferred.
    pub fn priority(self) -> u8 {
        match self {
            Path::Bluetooth => 0,
            Path::LocalWifi => 1,
            Path::Relay => 2,
        }
    }

    /// Whether this path can carry bulk (large file) traffic acceptably.
    pub fn suits_bulk(self) -> bool {
        !matches!(self, Path::Bluetooth)
    }
}

impl fmt::Display for Path {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Path::Bluetooth => "bluetooth",
            Path::LocalWifi => "local-wifi",
            Path::Relay => "relay",
        };
        f.write_str(s)
    }
}

/// Given the paths currently reachable to a peer and whether the payload is bulk,
/// choose the path to use. Bulk traffic skips Bluetooth even if it ranks first.
pub fn select(reachable: &[Path], is_bulk: bool) -> Option<Path> {
    reachable
        .iter()
        .copied()
        .filter(|p| !is_bulk || p.suits_bulk())
        .min_by_key(|p| p.priority())
}

/// The interface every concrete transport implements. Intentionally tiny; the
/// selector and the rest of the core only ever see opaque encrypted bytes.
///
/// (Async / streaming signatures will firm up alongside the iroh impl; this captures
/// the shape so the selector and FFI can be designed against it now.)
pub trait Transport {
    /// Which [`Path`] this transport represents.
    fn path(&self) -> Path;
    /// Whether this transport currently has a usable route to the given node id.
    fn is_reachable(&self, node_id: &[u8; 32]) -> bool;
}
