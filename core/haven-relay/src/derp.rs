//! Re-export of the shared Haven DERP role ([`haven_net::derp`]).
//! Kept as a module so `crate::derp::…` call sites in the CLI stay stable.

pub use haven_net::derp::{DerpConfig, DerpServer};
