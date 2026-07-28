//! Byte-exact port of the call signaling frames (iOS `CallManager` / Android `CallWire`).
//! Mesh group calls: a session id + roster; every participant opens one WebRTC connection to
//! every other (no SFU); the lexicographically smaller hex offers (glare-free). All call frames
//! lead with the sender's 64-char node-id hex so the engine can drop blocked senders.
//!
//!   21 group-invite : [hex64][lp sessionId][lp groupName][lp rosterCSV][lp sentAtSecs?]
//!   11 accept       : [hex64][lp sessionId]
//!   12 hangup       : [hex64]
//!   16/17/18 signal : [hex64][lp sessionId][json]   (offer / answer / ice — SDP or candidate JSON)
//!   10 legacy invite: [hex64][name utf8]
//!
//! The WebRTC media + mesh logic itself lives in the WebView (`ui/app.js`) using the browser's
//! `RTCPeerConnection`; this module is only the wire framing the engine routes.

use crate::wire::{self, lp_append};

fn hex_head(payload: &[u8]) -> Option<String> {
    if payload.len() < 64 {
        return None;
    }
    let from = String::from_utf8_lossy(&payload[..64]).into_owned();
    if from.len() == 64 {
        Some(from)
    } else {
        None
    }
}

// ---- builders ----

/// The 4th LP field is the send time (unix seconds, decimal) so receivers can refuse to ring for
/// a stale relay-replayed copy; every platform's parser tolerates trailing fields, so older
/// receivers are unaffected.
pub fn group_invite(
    my_hex: &str,
    session_id: &str,
    group_name: &str,
    roster_csv: &str,
    sent_at_secs: u64,
) -> Vec<u8> {
    let mut out = my_hex.as_bytes().to_vec();
    lp_append(&mut out, session_id.as_bytes());
    lp_append(&mut out, group_name.as_bytes());
    lp_append(&mut out, roster_csv.as_bytes());
    lp_append(&mut out, sent_at_secs.to_string().as_bytes());
    out
}

pub fn accept(my_hex: &str, session_id: &str) -> Vec<u8> {
    let mut out = my_hex.as_bytes().to_vec();
    lp_append(&mut out, session_id.as_bytes());
    out
}

/// Frame 12 — NAMES ITS SESSION, same shape as [`accept`].
///
/// It used to be the bare sender hex, which makes a hangup impossible to attribute: hangups are
/// retransmitted and a relay can deliver one late, so a BYE from a call that ended minutes ago still
/// arrives and the receiver cannot tell it from a live one. It would end whatever call was running —
/// an outgoing call whose screen appears and vanishes, or a connected call that hangs itself up.
/// Appending the session is backward compatible: a reader that only takes the leading 64 bytes is
/// unaffected. iOS/Android parity.
pub fn hangup(my_hex: &str, session_id: &str) -> Vec<u8> {
    accept(my_hex, session_id)
}

/// Frame 30 — same shape as `accept`, so the receiver reads the session it names (and `parse_accept`
/// decodes it).
pub fn handled_elsewhere(my_hex: &str, session_id: &str) -> Vec<u8> {
    accept(my_hex, session_id)
}

/// Frame 22 body: `[hex64][lp sessionId][on byte]` — tell peers my camera is on/off, so they show my
/// avatar rather than a frozen last frame.
pub fn camera_state(my_hex: &str, session_id: &str, on: bool) -> Vec<u8> {
    let mut out = my_hex.as_bytes().to_vec();
    lp_append(&mut out, session_id.as_bytes());
    out.push(if on { 1 } else { 0 });
    out
}

/// `(from, camera_on)`. iOS/Android read only the leading hex and the trailing flag byte, so we
/// match that rather than re-parsing the session id.
pub fn parse_camera_state(payload: &[u8]) -> Option<(String, bool)> {
    let from = hex_head(payload)?;
    let on = payload.last().copied() == Some(1);
    Some((from, on))
}

/// offer/answer/ice body: `[hex64][lp sessionId][json]`.
pub fn signal(my_hex: &str, session_id: &str, json: &[u8]) -> Vec<u8> {
    let mut out = my_hex.as_bytes().to_vec();
    lp_append(&mut out, session_id.as_bytes());
    out.extend_from_slice(json);
    out
}

// ---- parsers ----

pub struct GroupInvite {
    pub from: String,
    pub session_id: String,
    pub group_name: String,
    pub roster: Vec<String>,
    /// Send time (unix seconds); `None` when the sender predates the timestamp field.
    pub sent_at: Option<u64>,
}

pub fn parse_group_invite(payload: &[u8]) -> Option<GroupInvite> {
    let from = hex_head(payload)?;
    let mut r = wire::Reader::new(payload);
    r.off = 64;
    let sid = String::from_utf8_lossy(&r.lp()?).into_owned();
    let gname = String::from_utf8_lossy(&r.lp()?).into_owned();
    let roster_str = String::from_utf8_lossy(&r.lp()?).into_owned();
    if sid.is_empty() {
        return None;
    }
    let roster = roster_str
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| s.len() == 64)
        .collect();
    let sent_at = r.lp().and_then(|b| String::from_utf8_lossy(&b).parse::<u64>().ok());
    Some(GroupInvite {
        from,
        session_id: sid,
        group_name: if gname.is_empty() { "Group call".into() } else { gname },
        roster,
        sent_at,
    })
}

pub struct Accept {
    pub from: String,
    pub session_id: String,
}

pub fn parse_accept(payload: &[u8]) -> Option<Accept> {
    let from = hex_head(payload)?;
    let mut r = wire::Reader::new(payload);
    r.off = 64;
    let sid = r.lp().map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
    Some(Accept { from, session_id: sid })
}

/// The sender hex, plus the session it names when the sender is new enough to include one.
/// Older senders omit it — those still apply, so gating on it only ever tightens behaviour.
pub fn parse_hangup(payload: &[u8]) -> Option<(String, String)> {
    let from = hex_head(payload)?;
    let mut r = wire::Reader::new(payload);
    r.off = 64;
    let sid = r.lp().map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
    Some((from, sid))
}

pub fn parse_invite_name(payload: &[u8]) -> Option<(String, String)> {
    let from = hex_head(payload)?;
    let name = if payload.len() > 64 {
        String::from_utf8_lossy(&payload[64..]).into_owned()
    } else {
        "Someone".into()
    };
    Some((from, name))
}

pub struct Signal {
    pub from: String,
    pub session_id: String,
    pub json: Vec<u8>,
}

/// Decode `[hex64][lp sessionId?][json]`. The session id is optional (legacy 1:1 frames omit
/// it); JSON always starts with `{`, which disambiguates the legacy framing.
pub fn parse_signal(payload: &[u8], fallback_session: &str) -> Option<Signal> {
    let from = hex_head(payload)?;
    let body = &payload[64..];
    if body.is_empty() {
        return None;
    }
    let mut r = wire::Reader::new(body);
    let off_before = r.off;
    if let Some(sid_bytes) = r.lp() {
        let sid = String::from_utf8_lossy(&sid_bytes).into_owned();
        if !sid.is_empty() && r.off < body.len() && body[r.off] == b'{' {
            return Some(Signal { from, session_id: sid, json: body[r.off..].to_vec() });
        }
    }
    // Legacy: body is raw JSON; infer the session.
    let _ = off_before;
    Some(Signal { from, session_id: fallback_session.to_string(), json: body.to_vec() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_invite_roundtrip() {
        let me = "a".repeat(64);
        let p = group_invite(&me, "sess1", "Family call", &format!("{},{}", "b".repeat(64), "c".repeat(64)), 1_770_000_000);
        let g = parse_group_invite(&p).unwrap();
        assert_eq!(g.from, me);
        assert_eq!(g.session_id, "sess1");
        assert_eq!(g.group_name, "Family call");
        assert_eq!(g.roster.len(), 2);
        assert_eq!(g.sent_at, Some(1_770_000_000));
    }

    #[test]
    fn group_invite_tolerates_trailing_timestamp_field() {
        // Senders append a 4th length-prefixed field (unix-seconds send time) so receivers can
        // refuse stale replayed invites. The builder now emits it itself; the parser must surface
        // it, and any FUTURE unknown 5th field must still be ignored, not break the call.
        let me = "a".repeat(64);
        let mut p = group_invite(&me, "sess1", "Family call", &"b".repeat(64), 1_770_000_000);
        let extra = b"future-field";
        p.extend_from_slice(&(extra.len() as u16).to_le_bytes());
        p.extend_from_slice(extra);
        let g = parse_group_invite(&p).unwrap();
        assert_eq!(g.session_id, "sess1");
        assert_eq!(g.roster.len(), 1);
        assert_eq!(g.sent_at, Some(1_770_000_000));
    }

    #[test]
    fn group_invite_without_timestamp_parses_with_no_sent_at() {
        // A frame from an OLDER sender (3 fields, no timestamp) must still parse; sent_at is None
        // so the receiver never treats it as stale.
        let me = "a".repeat(64);
        let mut p = me.as_bytes().to_vec();
        lp_append(&mut p, b"sess1");
        lp_append(&mut p, b"Family call");
        lp_append(&mut p, "b".repeat(64).as_bytes());
        let g = parse_group_invite(&p).unwrap();
        assert_eq!(g.session_id, "sess1");
        assert_eq!(g.sent_at, None);
    }

    #[test]
    fn signal_roundtrip() {
        let me = "a".repeat(64);
        let json = br#"{"t":"offer","sdp":"x"}"#;
        let p = signal(&me, "sess1", json);
        let s = parse_signal(&p, "fallback").unwrap();
        assert_eq!(s.from, me);
        assert_eq!(s.session_id, "sess1");
        assert_eq!(s.json, json);
    }

    #[test]
    fn legacy_signal_without_session() {
        let me = "a".repeat(64);
        let mut p = me.as_bytes().to_vec();
        p.extend_from_slice(br#"{"t":"answer","sdp":"y"}"#);
        let s = parse_signal(&p, "fallback").unwrap();
        assert_eq!(s.session_id, "fallback");
        assert!(s.json.starts_with(b"{"));
    }
}
