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
//! marked. The sealing described above is multi-recipient public-key encryption. As of
//! 1.0.7 that is no longer the only keying path: per-message forward secrecy and
//! post-compromise security come from the MLS-style ratchet-tree layer in
//! [`crate::treekem`] — TreeKEM over Haven's own post-quantum primitives, deliberately
//! **not** RFC-9420 wire-interoperable and **not** `mls-rs` (every ratified MLS
//! ciphersuite is classical, so interop would regress the PQ posture). It is enabled
//! for circles with a verified owner and activates per circle as members update, so
//! both paths stay live. This module's envelope format is unchanged either way — the
//! tree only changes how the epoch key is *agreed*. See `docs/TREEKEM-DESIGN.md` for
//! what shipped; `docs/DECISIONS.md` D3 records the ORIGINAL decision this layer
//! supersedes (RFC 9420 via `mls-rs`) and still reads as if that were the plan.

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

/// Tags a binary envelope. Absent on the legacy JSON form, which always starts with `{`.
const ENVELOPE_MAGIC: &[u8; 4] = b"HVE1";

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
    ///
    /// COMPACT BINARY, tagged. `serde_json` renders every `Vec<u8>` as an array of decimal numbers,
    /// so the ciphertext cost ~3.6 bytes of ASCII per byte of data: a 48 MB video was a 167 MB blob
    /// on disk, and opening it meant parsing 167 MB of text into a fresh 48 MB buffer. On a phone
    /// with a 192 MB heap cap and ~180 MB free that cannot succeed at any layer — the native
    /// file-to-file path could not save it either, because the bloat is in the container, not the
    /// caller. Photos and videos simply never rendered, and the failure looked like a decrypt error.
    ///
    /// The signature is computed over [`Self::transcript`], which hashes the FIELDS, not their
    /// serialized form — so changing the container does not touch signing or verification.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(64 + self.ciphertext.len());
        out.extend_from_slice(ENVELOPE_MAGIC);
        out.extend_from_slice(&postcard::to_allocvec(self).expect("envelope serializes"));
        out
    }

    /// Parse from transport / storage — binary if tagged, else legacy JSON.
    ///
    /// Every blob already written is JSON and stays readable forever: content-addressed media is
    /// never re-sealed, so a device that drops JSON support would permanently lose media it already
    /// holds. A JSON envelope always begins with `{`, which no postcard encoding can start with,
    /// because the tag is checked first.
    pub fn from_bytes(b: &[u8]) -> Result<Self> {
        if let Some(rest) = b.strip_prefix(ENVELOPE_MAGIC) {
            return postcard::from_bytes(rest).map_err(|_| CoreError::Encoding("malformed envelope"));
        }
        serde_json::from_slice(b).map_err(|_| CoreError::Encoding("malformed envelope"))
    }

    /// Node ids (hex) this envelope was wrapped to. DIAGNOSIS ONLY — reveals nothing a holder of
    /// the blob cannot already read, and answers the one question a failed open cannot: "was I even
    /// a recipient?" A member who joined after a blob was sealed never is, and media is never
    /// re-sealed, so that case is invisible without this.
    pub fn recipient_ids_hex(&self) -> Vec<String> {
        self.recipients.iter().map(|r| hex(&r.member)).collect()
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

/// A reserved pseudo-member standing for "the circle EPOCH itself".
///
/// Media used to be readable ONLY by whoever was on its recipient list when it was sealed, and a
/// content-addressed blob is never re-sealed — so a member who joined later could read a post's
/// text (they hold the epoch) but never its photos, permanently. Adding the epoch as one more
/// recipient fixes that without giving up the property the recipient list provides: a friend whose
/// epoch keys have not converged still opens the blob by their own account key, exactly as before.
///
/// It is a normal entry in the existing list, so an older build simply doesn't match it against its
/// own node id and is unaffected — no format break, no second envelope type.
pub const EPOCH_RECIPIENT: [u8; 32] = *b"haven!epoch!recipient!marker!v1\0";

/// KEK for the epoch pseudo-recipient. Domain-separated so it can never collide with an event key
/// derived from the same epoch secret.
fn epoch_wrap_kek(epoch_key: &[u8; 32]) -> [u8; 32] {
    let mut h = blake3::Hasher::new_keyed(epoch_key);
    h.update(b"haven-media-epoch-wrap-v1");
    *h.finalize().as_bytes()
}

/// [`seal_bytes`] plus an epoch-wrapped copy of the content key, so ANY holder of the circle epoch
/// opens it — including members who joined after this blob was sealed.
pub fn seal_bytes_with_epoch(
    sender: &Identity,
    group: &Group,
    epoch_key: &[u8; 32],
    bytes: &[u8],
) -> Result<SealedEnvelope> {
    let mut content_key = [0u8; 32];
    OsRng.fill_bytes(&mut content_key);
    let ciphertext = seal(&content_key, bytes);

    let mut recipients = Vec::with_capacity(group.members.len() + 1);
    for member in &group.members {
        let (enc, kek) = encapsulate_to(member)?;
        recipients.push(RecipientKey {
            member: member.node_id_bytes().to_vec(),
            enc: EncWire { eph_x_pub: enc.eph_x_pub.to_vec(), pq_ct: enc.pq_ct },
            wrapped: seal(&kek, &content_key),
        });
    }
    // The epoch entry. No KEM material: the "key agreement" already happened when the circle
    // distributed its epoch key, which is precisely why a later joiner can use it.
    recipients.push(RecipientKey {
        member: EPOCH_RECIPIENT.to_vec(),
        enc: EncWire { eph_x_pub: Vec::new(), pq_ct: Vec::new() },
        wrapped: seal(&epoch_wrap_kek(epoch_key), &content_key),
    });

    let mut env = SealedEnvelope {
        sender: sender.public().node_id_bytes().to_vec(),
        ciphertext,
        recipients,
        signature: Vec::new(),
    };
    env.signature = sender.sign(&env.transcript());
    Ok(env)
}

/// Open a blob via its EPOCH entry — the path a member who joined after it was sealed must use.
/// Returns None when this envelope carries no epoch entry (every blob sealed before this shipped)
/// or when `epoch_key` is not the epoch it was sealed under.
pub fn open_bytes_with_epoch(epoch_key: &[u8; 32], env: &SealedEnvelope) -> Option<Vec<u8>> {
    let entry = env.recipients.iter().find(|r| r.member == EPOCH_RECIPIENT)?;
    let content_key = open(&epoch_wrap_kek(epoch_key), &entry.wrapped).ok()?;
    let ck: [u8; 32] = content_key.try_into().ok()?;
    open(&ck, &env.ciphertext).ok()
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

/// Freshness clamp (audit M2): `created_at` is author-supplied, so a malicious member could
/// far-future-date an event to pin it to the top of the feed forever or dodge a poll-close /
/// retention. Ignore anything dated more than a day ahead of the viewer's clock (generous enough
/// to absorb honest device skew); it simply surfaces once that time legitimately arrives.
const FUTURE_TOLERANCE_MS: u64 = 24 * 60 * 60 * 1000;

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

    // Freshness clamp — see [`FUTURE_TOLERANCE_MS`].
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

// ----- Activity reduction -----

/// One row of the activity feed — "what happened that concerns me": someone reacted to,
/// commented on, or voted on MY event, posted to a shared circle, or messaged a DM.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivityItem {
    /// The originating event's id.
    pub id: String,
    /// `"react" | "comment" | "vote" | "post" | "story" | "dm"`.
    pub kind: String,
    /// FULL node hex of who did it (the UI resolves a display name).
    pub actor_hex: String,
    /// The parent post/comment/poll id where applicable (reactions, comments, votes).
    pub target_id: Option<String>,
    /// Body prefix (~120 chars) for the preview line.
    pub snippet: String,
    pub created_at: u64,
    /// The reaction emoji (kind == "react").
    pub emoji: Option<String>,
}

/// Body prefix for an activity row (~120 chars, char-boundary safe).
fn snippet(body: &str) -> String {
    body.chars().take(120).collect()
}

/// Reduce one circle's decrypted events into activity rows, newest-first: reactions / comments /
/// votes on events *I* authored, others' posts and stories, and messages (`"dm"` when `circle_id`
/// is `dm:`-prefixed, else they render like posts). My own actions never notify me. Mirrors
/// [`build_feed`]'s pairing: a reaction removed by a LATER `Unreact` from the same author (same
/// target + emoji) yields no row, only an author's latest pre-close vote counts, and an event its
/// author later `Unsend`s is dropped. `since_ms` is the caller's watermark — rows dated before it
/// are skipped.
pub fn build_activity(
    mut events: Vec<Event>,
    me: &str,
    circle_id: &str,
    since_ms: u64,
    now_ms: u64,
) -> Vec<ActivityItem> {
    // Same deterministic order + freshness clamp as build_feed.
    events.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));
    events.dedup_by(|a, b| a.id == b.id);
    let horizon = now_ms.saturating_add(FUTURE_TOLERANCE_MS);
    events.retain(|e| e.created_at <= horizon);

    // One pass in time order to learn who authored what (targets are event ids), poll close
    // times, and the pairings that net rows out: the surviving reaction per (author, target,
    // emoji), the latest pre-close vote per (author, poll), and author-confirmed unsends.
    let author_of: BTreeMap<&str, &str> =
        events.iter().map(|e| (e.id.as_str(), e.author.as_str())).collect();
    let mine = |target: &str| author_of.get(target).copied() == Some(me);
    let mut poll_close: BTreeMap<&str, u64> = BTreeMap::new();
    let mut live_reacts: BTreeMap<(&str, &str, &str), &str> = BTreeMap::new();
    let mut live_votes: BTreeMap<(&str, &str), &str> = BTreeMap::new();
    let mut unsent: Vec<&str> = Vec::new();
    for e in &events {
        match &e.kind {
            EventKind::Poll { close_at_ms, .. } => {
                poll_close.insert(e.id.as_str(), *close_at_ms);
            }
            EventKind::Reaction { target, emoji } => {
                live_reacts.insert((e.author.as_str(), target.as_str(), emoji.as_str()), e.id.as_str());
            }
            EventKind::Unreact { target, emoji } => {
                live_reacts.remove(&(e.author.as_str(), target.as_str(), emoji.as_str()));
            }
            EventKind::Vote { target, .. } => {
                // Votes at/after a poll's close are ignored, exactly as build_feed tallies.
                let locked = poll_close.get(target.as_str()).is_some_and(|c| *c != 0 && e.created_at >= *c);
                if !locked {
                    live_votes.insert((e.author.as_str(), target.as_str()), e.id.as_str());
                }
            }
            EventKind::Unsend { target } => {
                if author_of.get(target.as_str()) == Some(&e.author.as_str()) {
                    unsent.push(target.as_str());
                }
            }
            _ => {}
        }
    }
    let live_reacts: Vec<&str> = live_reacts.into_values().collect();
    let live_votes: Vec<&str> = live_votes.into_values().collect();

    let is_dm = circle_id.starts_with("dm:");
    let mut out = Vec::new();
    for e in events.iter().rev() {
        // My own actions never notify me; rows before the watermark are the caller's already.
        if e.created_at < since_ms || e.author == me || unsent.contains(&e.id.as_str()) {
            continue;
        }
        let (kind, target_id, body, emoji) = match &e.kind {
            EventKind::Reaction { target, emoji } if mine(target) => {
                if !live_reacts.contains(&e.id.as_str()) {
                    continue;
                }
                ("react", Some(target.clone()), "", Some(emoji.clone()))
            }
            EventKind::Comment { target, body, .. } if mine(target) => {
                ("comment", Some(target.clone()), body.as_str(), None)
            }
            EventKind::Vote { target, .. } if mine(target) => {
                if !live_votes.contains(&e.id.as_str()) {
                    continue;
                }
                ("vote", Some(target.clone()), "", None)
            }
            EventKind::Post { body, story, .. } => {
                (if *story { "story" } else { "post" }, None, body.as_str(), None)
            }
            // A poll renders like a post; its question is the preview.
            EventKind::Poll { question, .. } => ("post", None, question.as_str(), None),
            EventKind::Message { body } => {
                (if is_dm { "dm" } else { "post" }, None, body.as_str(), None)
            }
            _ => continue,
        };
        out.push(ActivityItem {
            id: e.id.clone(),
            kind: kind.into(),
            actor_hex: e.author.clone(),
            target_id,
            snippet: snippet(body),
            created_at: e.created_at,
            emoji,
        });
    }
    out
}

/// Effective retention = the SHORTER of the sender's override and the viewer's
/// default (None = keep forever). Returns true once `created_at + retention` is past.
/// Public because the engine's `purge_expired` sweep must agree byte-for-byte with the
/// feed's hide decision — two implementations of "expired" would eventually disagree.
pub fn is_expired(
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
mod edit_tests {
    use super::*;

    fn ev(author: u8, t: u64, kind: EventKind) -> Event {
        Event::new(&[author; 32], t, kind)
    }

    fn post_with_media(author: u8, t: u64, media: Vec<String>) -> Event {
        ev(author, t, EventKind::Post {
            body: "beach day".into(),
            media,
            music: None,
            retention_secs: None,
            story: false,
            mute_video: false,
        })
    }

    /// An Edit REPLACES the media array — it does not merge.
    ///
    /// This is the contract every client has to honor, and Android did not: its post editor called
    /// `editPost(circle, id, body)` with the media parameter defaulted to empty, so fixing a typo in
    /// a caption deleted every photo on that post for the entire circle. The bytes survive, but the
    /// post stops referencing them everywhere, which for the user is the same as losing them.
    ///
    /// Pinned here, in the reducer's own crate, because the trap is shared by all four clients and
    /// the next one to add an edit affordance deserves to be caught by a test rather than by a
    /// member asking where their photos went.
    #[test]
    fn an_edit_replaces_media_so_omitting_it_strips_the_post() {
        let photos = vec!["ref-a".to_string(), "ref-b".to_string()];
        let post = post_with_media(1, 100, photos.clone());
        let pid = post.id.clone();

        // Baseline: the post carries both attachments.
        let feed = build_feed(vec![post.clone()], 500, None, None);
        assert_eq!(feed[0].media, photos, "precondition: the post starts with its media");

        // Editing the text WITHOUT re-supplying media wipes it. This is the bug's shape.
        let stripped = build_feed(vec![post.clone(), ev(1, 200, EventKind::Edit {
            target: pid.clone(), body: "beach day!".into(),
            media: vec![], music: None, mute_video: false,
        })], 500, None, None);
        assert_eq!(stripped[0].body, "beach day!");
        assert!(stripped[0].media.is_empty(),
            "an edit with no media clears it — callers MUST pass the current media back in");

        // Doing it correctly: carry the existing media through, and it survives.
        let kept = build_feed(vec![post, ev(1, 200, EventKind::Edit {
            target: pid, body: "beach day!".into(),
            media: photos.clone(), music: None, mute_video: false,
        })], 500, None, None);
        assert_eq!(kept[0].body, "beach day!");
        assert_eq!(kept[0].media, photos, "re-supplied media must be preserved across an edit");
    }

    /// Only the author can edit — a re-point of someone else's post must be ignored.
    #[test]
    fn a_non_author_edit_cannot_change_media() {
        let photos = vec!["ref-a".to_string()];
        let post = post_with_media(1, 100, photos.clone());
        let pid = post.id.clone();

        let feed = build_feed(vec![post, ev(2, 200, EventKind::Edit {
            target: pid, body: "hijacked".into(),
            media: vec!["attacker-ref".into()], music: None, mute_video: false,
        })], 500, None, None);

        assert_eq!(feed[0].body, "beach day", "a stranger's edit must not apply");
        assert_eq!(feed[0].media, photos, "and must not re-point the media");
    }
}

#[cfg(test)]
mod activity_tests {
    use super::*;

    fn ev(author: u8, t: u64, kind: EventKind) -> Event {
        Event::new(&[author; 32], t, kind)
    }

    fn post(author: u8, t: u64, body: &str) -> Event {
        ev(author, t, EventKind::Post {
            body: body.into(),
            media: vec![],
            music: None,
            retention_secs: None,
            story: false,
            mute_video: false,
        })
    }

    fn me() -> String {
        hex(&[1u8; 32])
    }

    #[test]
    fn react_then_unreact_nets_out() {
        let p = post(1, 100, "mine");
        let pid = p.id.clone();
        let react = ev(2, 200, EventKind::Reaction { target: pid.clone(), emoji: "❤️".into() });

        // A live reaction to MY post is a row (my own post is not — my actions never notify me) …
        let rows = build_activity(vec![p.clone(), react.clone()], &me(), "fam", 0, 1_000);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].kind, "react");
        assert_eq!(rows[0].target_id.as_deref(), Some(pid.as_str()));
        assert_eq!(rows[0].emoji.as_deref(), Some("❤️"));

        // … but reacting and then taking it back leaves nothing to announce.
        let unreact = ev(2, 300, EventKind::Unreact { target: pid, emoji: "❤️".into() });
        let rows = build_activity(vec![p, react, unreact], &me(), "fam", 0, 1_000);
        assert!(rows.is_empty(), "a retracted reaction must not survive as activity");
    }

    #[test]
    fn comments_only_count_on_my_events() {
        let my_post = post(1, 100, "mine");
        let their_post = post(2, 110, "theirs");
        let on_mine = ev(2, 200, EventKind::Comment {
            target: my_post.id.clone(), body: "nice".into(), media: vec![],
        });
        let on_theirs = ev(3, 210, EventKind::Comment {
            target: their_post.id.clone(), body: "cool".into(), media: vec![],
        });

        let rows = build_activity(
            vec![my_post.clone(), their_post, on_mine, on_theirs], &me(), "fam", 0, 1_000,
        );
        let comments: Vec<_> = rows.iter().filter(|r| r.kind == "comment").collect();
        assert_eq!(comments.len(), 1, "only the comment on MY post is my activity");
        assert_eq!(comments[0].target_id.as_deref(), Some(my_post.id.as_str()));
        assert_eq!(comments[0].snippet, "nice");
    }

    #[test]
    fn since_watermark_cuts_old_rows() {
        let old = post(2, 100, "old");
        let fresh = post(2, 500, "fresh");
        let rows = build_activity(vec![old, fresh], &me(), "fam", 300, 1_000);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].snippet, "fresh");
    }

    #[test]
    fn message_kind_follows_the_circle() {
        let msg = ev(2, 100, EventKind::Message { body: "hey".into() });
        let dm = build_activity(vec![msg.clone()], &me(), "dm:aa-bb", 0, 1_000);
        assert_eq!(dm[0].kind, "dm");
        let chat = build_activity(vec![msg], &me(), "fam", 0, 1_000);
        assert_eq!(chat[0].kind, "post");
    }

    #[test]
    fn rows_are_newest_first() {
        let a = post(2, 100, "a");
        let b = post(3, 300, "b");
        let c = post(4, 200, "c");
        let rows = build_activity(vec![a, b, c], &me(), "fam", 0, 1_000);
        let order: Vec<&str> = rows.iter().map(|r| r.snippet.as_str()).collect();
        assert_eq!(order, ["b", "c", "a"]);
    }
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

#[cfg(test)]
mod envelope_container_tests {
    use super::*;

    fn sealed() -> SealedEnvelope {
        let a = Identity::from_seed(&[7u8; 32]);
        let b = Identity::from_seed(&[9u8; 32]);
        let group = Group::new("default".to_string(), vec![a.public(), b.public()]);
        seal_bytes(&a, &group, b"a video's worth of bytes").expect("seals")
    }

    /// The new container is binary and TAGGED, and round-trips.
    #[test]
    fn binary_envelope_roundtrips_and_is_tagged() {
        let env = sealed();
        let bytes = env.to_bytes();
        assert!(bytes.starts_with(ENVELOPE_MAGIC), "new envelopes carry the tag");
        assert_ne!(bytes[0], b'{', "no longer JSON");
        let back = SealedEnvelope::from_bytes(&bytes).expect("parses");
        assert_eq!(back.sender_hex(), env.sender_hex());
        assert_eq!(back.ciphertext, env.ciphertext);
    }

    /// EVERY blob already on disk is JSON, and content-addressed media is never re-sealed — so
    /// dropping JSON support would permanently destroy media people already hold. This is the test
    /// that must never be deleted.
    #[test]
    fn legacy_json_envelopes_still_open() {
        let env = sealed();
        let legacy = serde_json::to_vec(&env).expect("legacy form");
        assert_eq!(legacy[0], b'{', "legacy really is JSON");
        let back = SealedEnvelope::from_bytes(&legacy).expect("legacy still parses");
        assert_eq!(back.sender_hex(), env.sender_hex());
        assert_eq!(back.ciphertext, env.ciphertext);
    }

    /// The whole point: JSON renders each ciphertext byte as ~3.6 bytes of ASCII, which is what made
    /// a 48 MB video a 167 MB blob no mid-range phone could parse.
    #[test]
    fn binary_container_is_dramatically_smaller_than_json() {
        let a = Identity::from_seed(&[7u8; 32]);
        let b = Identity::from_seed(&[9u8; 32]);
        let group = Group::new("default".to_string(), vec![a.public(), b.public()]);
        let payload = vec![0xABu8; 256 * 1024];
        let env = seal_bytes(&a, &group, &payload).expect("seals");
        let bin = env.to_bytes().len();
        let json = serde_json::to_vec(&env).expect("json").len();
        println!("payload={} binary={bin} json={json} ratio={:.2}x",
                 payload.len(), json as f64 / bin as f64);
        assert!(bin < json / 3, "binary {bin} should be far under a third of json {json}");
        // Fixed overhead is post-quantum key material — an ML-KEM ciphertext per recipient plus an
        // ML-DSA signature — so it is several KB before any payload, but it does NOT scale with the
        // payload. That is the property that matters: constant overhead, not a multiplier.
        assert!(bin < payload.len() + 32 * 1024,
                "binary {bin} should be payload {} plus constant crypto overhead", payload.len());
    }
}

#[cfg(test)]
mod epoch_recipient_tests {
    use super::*;

    /// THE bug this exists for: someone who was NOT on the recipient list — a member who joined
    /// after the blob was sealed — opens it with the circle epoch key.
    #[test]
    fn a_later_joiner_opens_it_by_epoch() {
        let author = Identity::from_seed(&[1u8; 32]);
        let original = Identity::from_seed(&[2u8; 32]);
        let joiner = Identity::from_seed(&[3u8; 32]);
        let epoch = [42u8; 32];
        // The joiner is deliberately absent from the recipient list.
        let group = Group::new("default".to_string(), vec![author.public(), original.public()]);
        let env = seal_bytes_with_epoch(&author, &group, &epoch, b"a photo").expect("seals");
        assert!(!env.recipient_ids_hex().contains(&hex(&joiner.public().node_id_bytes())));
        assert_eq!(open_bytes_with_epoch(&epoch, &env).as_deref(), Some(&b"a photo"[..]));
    }

    /// Isolation: every user's own circle is called "default", so the id collides by design. A
    /// different circle's epoch key must never open this blob.
    #[test]
    fn another_circles_epoch_cannot_open_it() {
        let author = Identity::from_seed(&[1u8; 32]);
        let group = Group::new("default".to_string(), vec![author.public()]);
        let env = seal_bytes_with_epoch(&author, &group, &[42u8; 32], b"private").expect("seals");
        assert!(open_bytes_with_epoch(&[43u8; 32], &env).is_none(),
                "a stranger's circle must never open my media");
    }

    /// The property the epoch entry must NOT cost us: a listed recipient still opens it by their own
    /// key, with no epoch key at all — the friend whose epoch has not converged.
    #[test]
    fn a_listed_recipient_still_opens_it_without_any_epoch_key() {
        let author = Identity::from_seed(&[1u8; 32]);
        let friend = Identity::from_seed(&[2u8; 32]);
        let group = Group::new("default".to_string(), vec![author.public(), friend.public()]);
        let env = seal_bytes_with_epoch(&author, &group, &[42u8; 32], b"a photo").expect("seals");
        let out = open_bytes(&friend, &author.public(), &env).expect("opens by account key");
        assert_eq!(out, b"a photo");
    }

    /// A blob sealed WITHOUT an epoch (a circle that has not keyed) has no epoch entry, and asking
    /// for one must fail cleanly rather than mis-open.
    #[test]
    fn a_blob_with_no_epoch_entry_reports_none() {
        let author = Identity::from_seed(&[1u8; 32]);
        let group = Group::new("default".to_string(), vec![author.public()]);
        let env = seal_bytes(&author, &group, b"a photo").expect("seals");
        assert!(open_bytes_with_epoch(&[42u8; 32], &env).is_none());
    }
}
