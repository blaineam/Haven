//! The social layer: groups, posts, comments, reactions, messages — and edit /
//! unsend — all end-to-end encrypted with the hybrid post-quantum primitives.
//!
//! ## Model
//! A [`Group`] is a set of member public identities. Every social action is an
//! [`Event`] authored and **hybrid-signed** by its sender, then **sealed to the
//! group**: a fresh content key encrypts the event (AES-256-GCM), and that key is
//! wrapped to each member via the hybrid KEM (X25519 + ML-KEM-768). Any member
//! decrypts; nobody else can. The resulting [`SealedEnvelope`] is what travels over
//! the wire or parks in storage — opaque to relays.
//!
//! [`build_feed`] reduces a stream of decrypted events into a timeline: posts with
//! their comments and reactions, edits applied (with an "edited" flag), and unsends
//! marked. This is multi-recipient public-key encryption, not yet MLS — it works and
//! is fully tested; forward-secrecy via MLS (`mls-rs`) is a later hardening (see
//! `docs/DECISIONS.md` D3).

use std::collections::BTreeMap;

use rand::rngs::OsRng;
use rand::RngCore;
use serde::{Deserialize, Serialize};

use crate::crypto::{decapsulate, encapsulate_to, open, seal, Encapsulation};
use crate::identity::{Identity, HavenId};
use crate::{CoreError, Result};

/// A reference to an Apple Music track attached to a post. This is *reference data
/// only* — never audio. Each viewer plays it through their own subscription. It is
/// serialized inside the already-sealed event, so it leaks nothing to a relay.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrackRef {
    pub catalog_id: String,
    pub title: String,
    pub artist: String,
    pub artwork_url: String,
    pub duration_ms: u64,
}

/// What a social event *is*. Targets reference another event's id.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum EventKind {
    /// A feed post: text, optional media content-refs, an optional song, and an
    /// optional sender-set retention (seconds; the post is dropped after this).
    Post { body: String, media: Vec<String>, music: Option<TrackRef>, retention_secs: Option<u64>, story: bool, #[serde(default)] mute_video: bool },
    /// A direct/group message (rendered as a post in a 1:1 or chat group).
    Message { body: String },
    /// A comment on a post/message — text and/or media (a rich-media reply).
    Comment { target: String, body: String, media: Vec<String> },
    /// A reaction (emoji) to a post/message.
    Reaction { target: String, emoji: String },
    /// Remove *your own* prior reaction (emoji) from a post/message.
    Unreact { target: String, emoji: String },
    /// Edit the body of one of *your own* prior events.
    Edit { target: String, body: String, media: Vec<String>, music: Option<TrackRef>, #[serde(default)] mute_video: bool },
    /// Retract ("unsend") one of *your own* prior events.
    Unsend { target: String },
    /// Mark a media content-ref as sensitive (e.g. an Apple client's on-device Sensitive Content
    /// Analysis flagged it). Additive + irrevocable: once any circle member flags a ref every
    /// client treats it as sensitive — so one member with SCA protects members on platforms with
    /// no equivalent. `target` is the media content-ref (content-addressed → identical everywhere).
    SensitiveFlag { target: String },
    /// A member-filed report of another member's event (objectionable content / abuse) — the
    /// decentralized moderation signal. Haven circles have no owner: every member holds their own
    /// removal power, so a report is sealed to the WHOLE circle and each member acts with the power
    /// they already have (hide for themselves, remove the author from their circle, block).
    /// `target` is the reported event id; `author` is that event's author (FULL node hex), embedded
    /// so a device that never received the target event can still act on its author. Older clients
    /// fail to parse this variant and drop the single event — safe to ship incrementally.
    Report { target: String, author: String, reason: String, #[serde(default)] comment: String },
    /// A poll: a question + options, optionally auto-closing at `close_at_ms` (0 = never). Results
    /// lock at close — votes timestamped at/after `close_at_ms` are ignored by the reducer.
    Poll { question: String, options: Vec<String>, close_at_ms: u64 },
    /// A vote for one option of a poll. `target` = the poll event id; `option` = the option index.
    /// Latest vote per author wins (you can change your vote until the poll closes).
    Vote { target: String, option: u32 },
}

/// A signed, addressable social action.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Event {
    /// Stable id = BLAKE3(author ‖ created_at ‖ kind). Used for dedup and as a target.
    pub id: String,
    /// Author's node id (hex).
    pub author: String,
    /// Caller-supplied timestamp (unix millis); the core has no clock.
    pub created_at: u64,
    pub kind: EventKind,
}

impl Event {
    /// Construct an event and compute its content-addressed id.
    pub fn new(author_node_id: &[u8; 32], created_at: u64, kind: EventKind) -> Self {
        let author = hex(author_node_id);
        let kind_bytes = serde_json::to_vec(&kind).expect("event kind serializes");
        let mut h = blake3::Hasher::new();
        h.update(b"haven-event-v1");
        h.update(author.as_bytes());
        h.update(&created_at.to_le_bytes());
        h.update(&kind_bytes);
        let id = hex(&h.finalize().as_bytes()[..16]);
        Self { id, author, created_at, kind }
    }
}

/// A group of members (their public identities). 1:1 is just two members.
#[derive(Clone)]
pub struct Group {
    pub id: String,
    pub members: Vec<HavenId>,
}

impl Group {
    pub fn new(id: impl Into<String>, members: Vec<HavenId>) -> Self {
        Self { id: id.into(), members }
    }
}

/// The KEM encapsulation, in a serializable wire form.
#[derive(Clone, Debug, Serialize, Deserialize)]
struct EncWire {
    eph_x_pub: Vec<u8>,
    pq_ct: Vec<u8>,
}

/// A content key wrapped to a single recipient.
#[derive(Clone, Debug, Serialize, Deserialize)]
struct RecipientKey {
    member: Vec<u8>, // node id
    enc: EncWire,
    wrapped: Vec<u8>, // AEAD(kek, content_key)
}

/// The opaque, on-wire form of a sealed event. Reveals nothing to a relay.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SealedEnvelope {
    sender: Vec<u8>, // sender node id
    ciphertext: Vec<u8>,
    recipients: Vec<RecipientKey>,
    signature: Vec<u8>, // hybrid signature over the transcript
}

impl SealedEnvelope {
    /// Sender node id (hex) — lets the recipient pick the right verifying key.
    pub fn sender_hex(&self) -> String {
        hex(&self.sender)
    }

    /// Serialize for transport / storage.
    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("envelope serializes")
    }

    /// Parse from transport / storage.
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        serde_json::from_slice(b).map_err(|_| CoreError::Encoding("malformed envelope"))
    }

    /// Transcript that the signature covers (binds ciphertext + all recipient entries).
    fn transcript(&self) -> [u8; 32] {
        let mut h = blake3::Hasher::new();
        h.update(b"haven-envelope-v1");
        h.update(&self.sender);
        h.update(&self.ciphertext);
        for r in &self.recipients {
            h.update(&r.member);
            h.update(&r.enc.eph_x_pub);
            h.update(&r.enc.pq_ct);
            h.update(&r.wrapped);
        }
        *h.finalize().as_bytes()
    }
}

/// Seal an event to every member of a group. Sender side.
pub fn seal_event(sender: &Identity, group: &Group, event: &Event) -> Result<SealedEnvelope> {
    let plaintext = serde_json::to_vec(event).map_err(|_| CoreError::Encoding("event"))?;

    // Fresh symmetric content key; encrypt the event once.
    let mut content_key = [0u8; 32];
    OsRng.fill_bytes(&mut content_key);
    let ciphertext = seal(&content_key, &plaintext);

    // Wrap the content key to each member via the hybrid KEM.
    let mut recipients = Vec::with_capacity(group.members.len());
    for member in &group.members {
        let (enc, kek) = encapsulate_to(member)?;
        recipients.push(RecipientKey {
            member: member.node_id_bytes().to_vec(),
            enc: EncWire { eph_x_pub: enc.eph_x_pub.to_vec(), pq_ct: enc.pq_ct },
            wrapped: seal(&kek, &content_key),
        });
    }

    let mut env = SealedEnvelope {
        sender: sender.public().node_id_bytes().to_vec(),
        ciphertext,
        recipients,
        signature: Vec::new(),
    };
    env.signature = sender.sign(&env.transcript());
    Ok(env)
}

/// Seal arbitrary bytes (e.g. a media blob) to every member of a group — any member
/// can open it. Used by the shared circle store so a volunteered bucket holds blobs
/// that are opaque to its host yet readable by the whole circle.
pub fn seal_bytes(sender: &Identity, group: &Group, bytes: &[u8]) -> Result<SealedEnvelope> {
    let mut content_key = [0u8; 32];
    OsRng.fill_bytes(&mut content_key);
    let ciphertext = seal(&content_key, bytes);

    let mut recipients = Vec::with_capacity(group.members.len());
    for member in &group.members {
        let (enc, kek) = encapsulate_to(member)?;
        recipients.push(RecipientKey {
            member: member.node_id_bytes().to_vec(),
            enc: EncWire { eph_x_pub: enc.eph_x_pub.to_vec(), pq_ct: enc.pq_ct },
            wrapped: seal(&kek, &content_key),
        });
    }
    let mut env = SealedEnvelope {
        sender: sender.public().node_id_bytes().to_vec(),
        ciphertext,
        recipients,
        signature: Vec::new(),
    };
    env.signature = sender.sign(&env.transcript());
    Ok(env)
}

/// Open group-sealed bytes addressed to me, verifying the sender. Recipient side.
pub fn open_bytes(me: &Identity, sender_pub: &HavenId, env: &SealedEnvelope) -> Result<Vec<u8>> {
    sender_pub.verify(&env.transcript(), &env.signature)?;
    let my_id = me.public().node_id_bytes().to_vec();
    let mine = env
        .recipients
        .iter()
        .find(|r| r.member == my_id)
        .ok_or(CoreError::Crypto("not a recipient of this envelope"))?;
    let eph: [u8; 32] = mine
        .enc
        .eph_x_pub
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::Crypto("bad ephemeral key"))?;
    let enc = Encapsulation { eph_x_pub: eph, pq_ct: mine.enc.pq_ct.clone() };
    let kek = decapsulate(me, &enc)?;
    let content_key_vec = open(&kek, &mine.wrapped)?;
    let content_key: [u8; 32] = content_key_vec
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::Crypto("bad content key"))?;
    open(&content_key, &env.ciphertext)
}

/// Open a sealed envelope addressed to me, verifying the sender's signature. Recipient side.
pub fn open_event(me: &Identity, sender_pub: &HavenId, env: &SealedEnvelope) -> Result<Event> {
    // 1. Authenticate the sender over the whole transcript before decrypting.
    sender_pub.verify(&env.transcript(), &env.signature)?;

    // 2. Find my wrapped key.
    let my_id = me.public().node_id_bytes().to_vec();
    let mine = env
        .recipients
        .iter()
        .find(|r| r.member == my_id)
        .ok_or(CoreError::Crypto("not a recipient of this envelope"))?;

    // 3. Unwrap the content key, then decrypt the event.
    let eph: [u8; 32] = mine
        .enc
        .eph_x_pub
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::Crypto("bad ephemeral key"))?;
    let enc = Encapsulation { eph_x_pub: eph, pq_ct: mine.enc.pq_ct.clone() };
    let kek = decapsulate(me, &enc)?;
    let content_key_vec = open(&kek, &mine.wrapped)?;
    let content_key: [u8; 32] = content_key_vec
        .as_slice()
        .try_into()
        .map_err(|_| CoreError::Crypto("bad content key"))?;
    let plaintext = open(&content_key, &env.ciphertext)?;

    let event: Event =
        serde_json::from_slice(&plaintext).map_err(|_| CoreError::Encoding("event decode"))?;

    // 4. The signed sender must match the event's claimed author.
    if event.author != hex(&env.sender) {
        return Err(CoreError::Crypto("author/sender mismatch"));
    }
    Ok(event)
}

// ----- Feed reduction -----

/// A reaction aggregate on a feed item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReactionGroup {
    pub emoji: String,
    pub count: u32,
    pub authors: Vec<String>,
}

/// One option of a poll with its current tally + the authors who voted for it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedPollOption {
    pub text: String,
    pub votes: u32,
    pub authors: Vec<String>,
}

/// A poll resolved on a feed item: options + tallies + close state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedPoll {
    pub question: String,
    pub options: Vec<FeedPollOption>,
    pub total_votes: u32,
    /// Epoch millis the poll auto-closes (0 = never). Once closed, results are locked.
    pub close_at_ms: u64,
    pub closed: bool,
}

/// A comment on a feed item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedComment {
    pub id: String,
    pub author: String,
    pub created_at: u64,
    pub body: String,
    pub media: Vec<String>,
    pub edited: bool,
    pub unsent: bool,
    pub reactions: Vec<ReactionGroup>,
}

/// A post/message with its comments and reactions resolved.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedItem {
    pub id: String,
    pub author: String,
    pub created_at: u64,
    pub body: String,
    pub media: Vec<String>,
    pub music: Option<TrackRef>,
    pub edited: bool,
    pub unsent: bool,
    pub story: bool,
    /// Author's choice: mute the attached video's own audio (e.g. so the song plays, or
    /// for a deliberately silent share). When false and there's no music, the video plays
    /// its own sound.
    pub mute_video: bool,
    pub comments: Vec<FeedComment>,
    pub reactions: Vec<ReactionGroup>,
    /// Present when this item is a poll. Tallies lock once `closed`.
    pub poll: Option<FeedPoll>,
}

/// Reduce a set of decrypted events into a timeline. Newest posts first; comments
/// oldest-first. Edits/unsends apply only to the original author's own events.
pub fn build_feed(
    mut events: Vec<Event>,
    now_ms: u64,
    viewer_retention_secs: Option<u64>,
    // When set to my own author hex, VIEWER auto-delete is skipped for my posts (my personal archive
    // stays even after others' posts age out of my feed). A sender-set expiry on my OWN post still
    // applies — that was my deliberate choice. `None` = viewer retention applies to everything.
    keep_own_author: Option<&str>,
) -> Vec<FeedItem> {
    // Deterministic order: by time, then id (dedup identical ids).
    events.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));
    events.dedup_by(|a, b| a.id == b.id);

    // Freshness clamp (audit M2): `created_at` is author-supplied, so a malicious member could
    // far-future-date an event to pin it to the top of the feed forever or dodge a poll-close /
    // retention. Ignore anything dated more than a day ahead of the viewer's clock (generous enough
    // to absorb honest device skew); it simply surfaces once that time legitimately arrives.
    const FUTURE_TOLERANCE_MS: u64 = 24 * 60 * 60 * 1000;
    let horizon = now_ms.saturating_add(FUTURE_TOLERANCE_MS);
    events.retain(|e| e.created_at <= horizon);

    let mut items: BTreeMap<String, FeedItem> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut comments: BTreeMap<String, FeedComment> = BTreeMap::new();
    let mut comment_order: Vec<String> = Vec::new();

    // Pass 1: create posts/messages and comments.
    for e in &events {
        match &e.kind {
            EventKind::Post { body, media, music, retention_secs, story, mute_video } => {
                // Skip viewer retention for my own posts when "keep my posts" is on (sender expiry still applies).
                let viewer = if keep_own_author == Some(e.author.as_str()) { None } else { viewer_retention_secs };
                if is_expired(e.created_at, *retention_secs, viewer, now_ms) {
                    continue;
                }
                order.push(e.id.clone());
                items.insert(
                    e.id.clone(),
                    FeedItem {
                        id: e.id.clone(),
                        author: e.author.clone(),
                        created_at: e.created_at,
                        body: body.clone(),
                        media: media.clone(),
                        music: music.clone(),
                        edited: false,
                        unsent: false,
                        story: *story,
                        mute_video: *mute_video,
                        comments: Vec::new(),
                        reactions: Vec::new(),
                        poll: None,
                    },
                );
            }
            EventKind::Message { body } => {
                if is_expired(e.created_at, None, viewer_retention_secs, now_ms) {
                    continue;
                }
                order.push(e.id.clone());
                items.insert(
                    e.id.clone(),
                    FeedItem {
                        id: e.id.clone(),
                        author: e.author.clone(),
                        created_at: e.created_at,
                        body: body.clone(),
                        media: Vec::new(),
                        music: None,
                        edited: false,
                        unsent: false,
                        story: false,
                        mute_video: false,
                        comments: Vec::new(),
                        reactions: Vec::new(),
                        poll: None,
                    },
                );
            }
            // A poll renders like a post (its question is the body) but carries tallies.
            EventKind::Poll { question, options, close_at_ms } => {
                if is_expired(e.created_at, None, viewer_retention_secs, now_ms) {
                    continue;
                }
                order.push(e.id.clone());
                items.insert(
                    e.id.clone(),
                    FeedItem {
                        id: e.id.clone(),
                        author: e.author.clone(),
                        created_at: e.created_at,
                        body: question.clone(),
                        media: Vec::new(),
                        music: None,
                        edited: false,
                        unsent: false,
                        story: false,
                        mute_video: false,
                        comments: Vec::new(),
                        reactions: Vec::new(),
                        poll: Some(FeedPoll {
                            question: question.clone(),
                            options: options.iter().map(|t| FeedPollOption { text: t.clone(), votes: 0, authors: Vec::new() }).collect(),
                            total_votes: 0,
                            close_at_ms: *close_at_ms,
                            closed: *close_at_ms != 0 && now_ms >= *close_at_ms,
                        }),
                    },
                );
            }
            EventKind::Comment { target: _, body, media } => {
                comment_order.push(e.id.clone());
                comments.insert(
                    e.id.clone(),
                    FeedComment {
                        id: e.id.clone(),
                        author: e.author.clone(),
                        created_at: e.created_at,
                        body: body.clone(),
                        media: media.clone(),
                        edited: false,
                        unsent: false,
                        reactions: Vec::new(),
                    },
                );
            }
            _ => {}
        }
    }

    // Pass 2: apply edits/unsends (author must match), then reactions.
    for e in &events {
        match &e.kind {
            EventKind::Edit { target, body, media, music, mute_video } => {
                if let Some(it) = items.get_mut(target) {
                    if it.author == e.author && !it.unsent {
                        it.body = body.clone();
                        it.media = media.clone();
                        it.music = music.clone();
                        it.mute_video = *mute_video;
                        it.edited = true;
                    }
                } else if let Some(c) = comments.get_mut(target) {
                    if c.author == e.author && !c.unsent {
                        c.body = body.clone();
                        c.media = media.clone();
                        c.edited = true;
                    }
                }
            }
            EventKind::Unsend { target } => {
                if let Some(it) = items.get_mut(target) {
                    if it.author == e.author {
                        it.unsent = true;
                        it.body.clear();
                        it.media.clear();
                        it.music = None;
                    }
                } else if let Some(c) = comments.get_mut(target) {
                    if c.author == e.author {
                        c.unsent = true;
                        c.body.clear();
                        c.media.clear();
                    }
                }
            }
            _ => {}
        }
    }

    // Tally poll votes: the latest vote per author wins (you can change your vote), and votes
    // timestamped at/after a poll's close are ignored — so the results lock at the close time.
    let mut poll_votes: BTreeMap<String, BTreeMap<String, u32>> = BTreeMap::new();
    for e in &events {
        if let EventKind::Vote { target, option } = &e.kind {
            if let Some(p) = items.get(target).and_then(|it| it.poll.as_ref()) {
                let locked = p.close_at_ms != 0 && e.created_at >= p.close_at_ms;
                if !locked && (*option as usize) < p.options.len() {
                    poll_votes.entry(target.clone()).or_default().insert(e.author.clone(), *option);
                }
            }
        }
    }
    for (poll_id, votes) in poll_votes {
        if let Some(p) = items.get_mut(&poll_id).and_then(|it| it.poll.as_mut()) {
            for (author, option) in votes {
                if let Some(opt) = p.options.get_mut(option as usize) {
                    opt.votes += 1;
                    opt.authors.push(author);
                }
            }
            p.total_votes = p.options.iter().map(|o| o.votes).sum();
        }
    }

    // Aggregate reactions onto their targets.
    // NOTE: this runs BEFORE comments are attached to their parent items so that a
    // comment's reactions are populated in the `comments` map first — the attach step
    // below clones each comment into its item, so reactions aggregated afterward would
    // never reach the cloned copies (post reactions were fine because they target
    // `items` directly, but comment reactions silently vanished).
    for e in &events {
        if let EventKind::Reaction { target, emoji } = &e.kind {
            let bucket: Option<&mut Vec<ReactionGroup>> = if let Some(it) = items.get_mut(target) {
                Some(&mut it.reactions)
            } else if let Some(c) = comments.get_mut(target) {
                Some(&mut c.reactions)   // reactions also work on comments
            } else {
                None
            };
            if let Some(reactions) = bucket {
                match reactions.iter_mut().find(|r| &r.emoji == emoji) {
                    Some(rg) => {
                        if !rg.authors.contains(&e.author) {
                            rg.authors.push(e.author.clone());
                            rg.count += 1;
                        }
                    }
                    None => reactions.push(ReactionGroup {
                        emoji: emoji.clone(),
                        count: 1,
                        authors: vec![e.author.clone()],
                    }),
                }
            }
        }
        if let EventKind::Unreact { target, emoji } = &e.kind {
            let bucket: Option<&mut Vec<ReactionGroup>> = if let Some(it) = items.get_mut(target) {
                Some(&mut it.reactions)
            } else if let Some(c) = comments.get_mut(target) {
                Some(&mut c.reactions)
            } else {
                None
            };
            if let Some(reactions) = bucket {
                if let Some(rg) = reactions.iter_mut().find(|r| &r.emoji == emoji) {
                    if let Some(pos) = rg.authors.iter().position(|a| a == &e.author) {
                        rg.authors.remove(pos);
                        rg.count = rg.count.saturating_sub(1);
                    }
                }
                reactions.retain(|r| !r.authors.is_empty());   // drop a group nobody holds anymore
            }
        }
    }

    // Attach comments to their targets (skip unsent comments). Done AFTER reaction
    // aggregation so each cloned comment carries its resolved reactions.
    for cid in &comment_order {
        if let (Some(comment), Some(target)) =
            (comments.get(cid).cloned(), comment_target(&events, cid))
        {
            if let Some(it) = items.get_mut(&target) {
                if !comment.unsent {
                    it.comments.push(comment);
                }
            }
        }
    }

    // Newest first.
    order
        .iter()
        .rev()
        .filter_map(|id| items.get(id).cloned())
        .collect()
}

/// Find the target post id for a comment event id.
fn comment_target(events: &[Event], comment_id: &str) -> Option<String> {
    events.iter().find_map(|e| match &e.kind {
        EventKind::Comment { target, .. } if e.id == comment_id => Some(target.clone()),
        _ => None,
    })
}

/// Effective retention = the SHORTER of the sender's override and the viewer's
/// default (None = keep forever). Returns true once `created_at + retention` is past.
fn is_expired(
    created_at_ms: u64,
    sender_secs: Option<u64>,
    viewer_secs: Option<u64>,
    now_ms: u64,
) -> bool {
    let effective = match (sender_secs, viewer_secs) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    };
    match effective {
        Some(secs) => now_ms >= created_at_ms.saturating_add(secs.saturating_mul(1000)),
        None => false,
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod poll_tests {
    use super::*;

    fn ev(author: u8, t: u64, kind: EventKind) -> Event {
        Event::new(&[author; 32], t, kind)
    }

    #[test]
    fn poll_tallies_latest_vote_per_author_and_locks_at_close() {
        let poll = ev(1, 100, EventKind::Poll {
            question: "Pizza tonight?".into(),
            options: vec!["Yes".into(), "No".into()],
            close_at_ms: 1000,
        });
        let pid = poll.id.clone();
        let events = vec![
            poll.clone(),
            ev(2, 200, EventKind::Vote { target: pid.clone(), option: 0 }), // B → Yes
            ev(3, 300, EventKind::Vote { target: pid.clone(), option: 1 }), // C → No
            ev(2, 400, EventKind::Vote { target: pid.clone(), option: 1 }), // B changes → No (latest wins)
            ev(4, 1500, EventKind::Vote { target: pid.clone(), option: 0 }), // D votes AFTER close → ignored
        ];

        // Before close: only B(No) + C(No) count; B's earlier Yes is superseded, D's late vote ignored.
        let p = build_feed(events.clone(), 500, None, None)
            .into_iter().find(|i| i.id == pid).unwrap().poll.unwrap();
        assert_eq!(p.options[0].votes, 0, "Yes: B moved away, D is post-close");
        assert_eq!(p.options[1].votes, 2, "No: B + C");
        assert_eq!(p.total_votes, 2);
        assert!(!p.closed);

        // After close: results are locked; the post-close vote is still ignored.
        let p2 = build_feed(events, 2000, None, None)
            .into_iter().find(|i| i.id == pid).unwrap().poll.unwrap();
        assert!(p2.closed);
        assert_eq!(p2.options[0].votes, 0);
        assert_eq!(p2.options[1].votes, 2);
    }
}
