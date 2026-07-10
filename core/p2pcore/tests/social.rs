//! Social layer: end-to-end sealed events + feed reduction (posts, comments,
//! reactions, edit, unsend), verified with the hybrid post-quantum primitives.

use p2pcore::identity::Identity;
use p2pcore::social::{
    build_feed, open_bytes, open_event, seal_bytes, seal_event, Event, EventKind, Group,
};

#[test]
fn group_sealed_bytes_round_trip() {
    let a = Identity::generate();
    let b = Identity::generate();
    let group = Group::new("fam", vec![a.public(), b.public()]);
    let blob = b"opaque media bytes for the shared store".to_vec();
    let env = seal_bytes(&a, &group, &blob).unwrap();
    // Another circle member opens it (the shared-store host could not).
    assert_eq!(open_bytes(&b, &a.public(), &env).unwrap(), blob);
    // The sealer opens it too.
    assert_eq!(open_bytes(&a, &a.public(), &env).unwrap(), blob);
    // A non-member cannot.
    let outsider = Identity::generate();
    assert!(open_bytes(&outsider, &a.public(), &env).is_err());
}

fn node_hex(id: &Identity) -> String {
    id.public()
        .node_id_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

#[test]
fn sealed_event_is_e2e_to_group_members_only() {
    let alice = Identity::generate();
    let bob = Identity::generate();
    let mallory = Identity::generate();
    let group = Group::new("fam", vec![alice.public(), bob.public()]);

    let event = Event::new(
        &alice.public().node_id_bytes(),
        1000,
        EventKind::Post { body: "beach day 🏖️".into(), media: vec![], music: None, retention_secs: None, story: false, mute_video: false },
    );
    let env = seal_event(&alice, &group, &event).expect("seal");

    // Bob (a member) opens it and gets the exact event back.
    let got = open_event(&bob, &alice.public(), &env).expect("bob opens");
    assert_eq!(got, event);

    // Mallory (not a member) cannot open it.
    assert!(open_event(&mallory, &alice.public(), &env).is_err());

    // A tampered ciphertext fails the sender signature check.
    let mut bytes = env.to_bytes();
    *bytes.last_mut().unwrap() ^= 0x01;
    let tampered = p2pcore::social::SealedEnvelope::from_bytes(&bytes);
    if let Ok(t) = tampered {
        assert!(open_event(&bob, &alice.public(), &t).is_err());
    }

    // Wrong sender key fails verification.
    assert!(open_event(&bob, &mallory.public(), &env).is_err());
}

#[test]
fn envelope_survives_serialization() {
    let alice = Identity::generate();
    let bob = Identity::generate();
    let group = Group::new("g", vec![alice.public(), bob.public()]);
    let event = Event::new(&alice.public().node_id_bytes(), 1, EventKind::Message { body: "hi".into() });
    let env = seal_event(&alice, &group, &event).unwrap();

    let round = p2pcore::social::SealedEnvelope::from_bytes(&env.to_bytes()).unwrap();
    assert_eq!(open_event(&bob, &alice.public(), &round).unwrap(), event);
}

#[test]
fn feed_resolves_posts_comments_reactions_edits_unsends() {
    let alice = Identity::generate();
    let bob = Identity::generate();
    let a = alice.public().node_id_bytes();
    let b = bob.public().node_id_bytes();
    let a_hex = node_hex(&alice);

    // Alice posts; Bob comments and reacts; Alice edits her post; Alice posts a
    // second thing then unsends it.
    let post = Event::new(&a, 100, EventKind::Post { body: "first".into(), media: vec!["blob1".into()], music: None, retention_secs: None, story: false, mute_video: false });
    let comment = Event::new(&b, 110, EventKind::Comment { target: post.id.clone(), body: "nice!".into(), media: vec![] });
    let react1 = Event::new(&b, 120, EventKind::Reaction { target: post.id.clone(), emoji: "❤️".into() });
    let react2 = Event::new(&a, 121, EventKind::Reaction { target: post.id.clone(), emoji: "❤️".into() });
    let edit = Event::new(&a, 130, EventKind::Edit { target: post.id.clone(), body: "first (fixed)".into(), media: vec![], music: None, mute_video: false });

    let post2 = Event::new(&a, 200, EventKind::Post { body: "oops".into(), media: vec![], music: None, retention_secs: None, story: false, mute_video: false });
    let unsend = Event::new(&a, 210, EventKind::Unsend { target: post2.id.clone() });

    let feed = build_feed(vec![
        post.clone(), comment, react1, react2, edit, post2.clone(), unsend,
    ], 1_000_000_000, None, None);

    assert_eq!(feed.len(), 2, "two posts in the feed");
    // Newest first → post2 then post.
    let item2 = &feed[0];
    assert_eq!(item2.id, post2.id);
    assert!(item2.unsent, "second post was unsent");
    assert!(item2.body.is_empty());

    let item1 = &feed[1];
    assert_eq!(item1.id, post.id);
    assert_eq!(item1.body, "first (fixed)");
    assert!(item1.edited, "post was edited");
    assert_eq!(item1.author, a_hex);
    assert_eq!(item1.comments.len(), 1);
    assert_eq!(item1.comments[0].body, "nice!");
    assert_eq!(item1.reactions.len(), 1);
    assert_eq!(item1.reactions[0].emoji, "❤️");
    assert_eq!(item1.reactions[0].count, 2, "two distinct reactors");
}

#[test]
fn cannot_edit_someone_elses_post() {
    let alice = Identity::generate();
    let bob = Identity::generate();
    let a = alice.public().node_id_bytes();
    let b = bob.public().node_id_bytes();

    let post = Event::new(&a, 1, EventKind::Post { body: "mine".into(), media: vec![], music: None, retention_secs: None, story: false, mute_video: false });
    // Bob tries to edit Alice's post.
    let forged_edit = Event::new(&b, 2, EventKind::Edit { target: post.id.clone(), body: "hacked".into(), media: vec![], music: None, mute_video: false });

    let feed = build_feed(vec![post.clone(), forged_edit], 1_000_000_000, None, None);
    assert_eq!(feed[0].body, "mine", "edit by non-author is ignored");
    assert!(!feed[0].edited);
}

#[test]
fn retention_drops_posts_past_the_shortest_window() {
    let a = Identity::generate().public().node_id_bytes();
    // Post at t=0ms. Sender retention 60s; nothing else.
    let p = Event::new(&a, 0, EventKind::Post {
        body: "vanishing".into(), media: vec![], music: None, retention_secs: Some(60), story: false, mute_video: false,
    });

    // Within the window → present.
    assert_eq!(build_feed(vec![p.clone()], 30_000, None, None).len(), 1);
    // Past the sender window (61s) → dropped.
    assert_eq!(build_feed(vec![p.clone()], 61_000, None, None).len(), 0);

    // Viewer default 10s is SHORTER than the sender's 60s → 10s wins.
    assert_eq!(build_feed(vec![p.clone()], 11_000, Some(10), None).len(), 0);

    // No retention anywhere → never expires.
    let q = Event::new(&a, 0, EventKind::Post {
        body: "forever".into(), media: vec![], music: None, retention_secs: None,
            story: false, mute_video: false,
    });
    assert_eq!(build_feed(vec![q], u64::MAX, None, None).len(), 1);
}
