//! Cross-platform push / local-notification banner copy.
//!
//! The iOS NSE can only show what the *sender* sealed into a tiny JSON blob (no circle engine
//! there). Android and desktop build the banner on the *recipient* from the newest inbound
//! feed item — but the **strings must match** so a reaction never says "Posted in …" on any
//! platform. This module is the single source of truth for those strings.
//!
//! Wire JSON (when sealing for APNs): `{ t, b, bp, c, k, e? }` — see Apple `PushBanner.swift`.

/// Kind tags — stable wire values.
pub mod kind {
    pub const POST: &str = "post";
    pub const STORY: &str = "story";
    pub const DM: &str = "dm";
    pub const REACT: &str = "react";
    pub const COMMENT: &str = "comment";
    pub const EDIT: &str = "edit";
    pub const UNSEND: &str = "unsend";
    pub const ACTIVITY: &str = "activity";
}

/// Full + private body lines for a banner.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BannerCopy {
    pub kind: &'static str,
    /// Full lock-screen body (may quote message text / emoji).
    pub body: String,
    /// Privacy-safe body (kind only — no quote, no emoji).
    pub private_body: String,
    pub emoji: Option<String>,
}

/// Clip a preview: collapse whitespace, redact secret-marker bodies, cap length.
pub fn clip(text: Option<&str>, limit: usize) -> Option<String> {
    let mut s = text?.trim().to_string();
    if s.is_empty() {
        return None;
    }
    // Secret messages: STX prefix (same as Apple SecretMessages / Android).
    if s.starts_with('\u{2}') {
        return Some("🔒 Secret message".into());
    }
    let collapsed: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    s = collapsed;
    if s.chars().count() > limit {
        s = s.chars().take(limit).collect::<String>().trim().to_string() + "…";
    }
    Some(s)
}

fn is_synthetic(ref_: &str) -> bool {
    ref_.find(':').is_some_and(|i| i > 1)
}

fn is_audio(ref_: &str) -> bool {
    ref_.starts_with("aud_") || ref_.starts_with("a:")
}

/// Banner for a post / story / DM (the common author path).
pub fn for_post(circle_id: &str, circle_name: &str, body: &str, media: &[&str], story: bool) -> BannerCopy {
    if story {
        return BannerCopy {
            kind: kind::STORY,
            body: format!("Shared a story in {circle_name}"),
            private_body: "Shared a story".into(),
            emoji: None,
        };
    }
    let real: Vec<&str> = media.iter().copied().filter(|r| !is_synthetic(r)).collect();
    if circle_id.starts_with("dm:") {
        let has_audio = real.iter().any(|r| is_audio(r));
        let has_media = !real.is_empty();
        if let Some(p) = clip(Some(body), 80) {
            return BannerCopy {
                kind: kind::DM,
                body: p,
                private_body: "Sent you a message".into(),
                emoji: None,
            };
        }
        let (body, privb) = if has_audio {
            ("Sent a voice note", "Sent a voice note")
        } else if has_media {
            ("Sent a photo", "Sent a photo")
        } else {
            ("Sent you a message", "Sent you a message")
        };
        return BannerCopy {
            kind: kind::DM,
            body: body.into(),
            private_body: privb.into(),
            emoji: None,
        };
    }
    let has_media = !real.is_empty();
    if let Some(p) = clip(Some(body), 80) {
        return BannerCopy {
            kind: kind::POST,
            body: format!("{circle_name}: {p}"),
            private_body: if has_media {
                "Shared a photo".into()
            } else {
                "Posted in your circle".into()
            },
            emoji: None,
        };
    }
    if has_media {
        BannerCopy {
            kind: kind::POST,
            body: format!("Shared a photo in {circle_name}"),
            private_body: "Shared a photo".into(),
            emoji: None,
        }
    } else {
        BannerCopy {
            kind: kind::POST,
            body: format!("Posted in {circle_name}"),
            private_body: "Posted in your circle".into(),
            emoji: None,
        }
    }
}

pub fn for_reaction(emoji: &str, circle_id: &str) -> BannerCopy {
    let is_dm = circle_id.starts_with("dm:");
    let e = if emoji.is_empty() { "👍" } else { emoji };
    BannerCopy {
        kind: kind::REACT,
        body: if is_dm {
            format!("Reacted {e} to your message")
        } else {
            format!("Reacted {e} to your post")
        },
        private_body: if is_dm {
            "Reacted to your message".into()
        } else {
            "Reacted to your post".into()
        },
        emoji: Some(e.to_string()),
    }
}

pub fn for_comment(body: &str, circle_id: &str, circle_name: &str) -> BannerCopy {
    let is_dm = circle_id.starts_with("dm:");
    if let Some(p) = clip(Some(body), 80) {
        return BannerCopy {
            kind: kind::COMMENT,
            body: if is_dm {
                format!("Replied: {p}")
            } else {
                format!("Commented in {circle_name}: {p}")
            },
            private_body: if is_dm {
                "Replied to your message".into()
            } else {
                "Left a comment".into()
            },
            emoji: None,
        };
    }
    BannerCopy {
        kind: kind::COMMENT,
        body: if is_dm {
            "Replied to your message".into()
        } else {
            format!("Commented in {circle_name}")
        },
        private_body: if is_dm {
            "Replied to your message".into()
        } else {
            "Left a comment".into()
        },
        emoji: None,
    }
}

/// Recipient-side: pick which body to show given a privacy detail level.
/// `detail`: "full" | "private" | "minimal"
pub fn display_body(full: &str, private_body: Option<&str>, kind_tag: Option<&str>, detail: &str) -> (bool, String) {
    match detail {
        "minimal" => (false, "New activity".into()),
        "private" => {
            let b = private_body
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
                .unwrap_or_else(|| fallback_private(kind_tag));
            (true, b)
        }
        _ => (true, full.to_string()),
    }
}

fn fallback_private(kind_tag: Option<&str>) -> String {
    match kind_tag {
        Some(kind::STORY) => "Shared a story".into(),
        Some(kind::REACT) => "Reacted to your post".into(),
        Some(kind::COMMENT) => "Left a comment".into(),
        Some(kind::DM) => "Sent you a message".into(),
        Some(kind::EDIT) => "Edited a message".into(),
        Some(kind::UNSEND) => "Unsent a message".into(),
        Some(kind::POST) => "Shared something".into(),
        _ => "New activity".into(),
    }
}

/// Best-effort banner from a received feed item's fields (Android/desktop recipient path).
/// `kind_hint`: optional "react" when the newest item is only a reaction bump — feed items are
/// usually posts; reactions may surface as posts with empty body + reaction list. Callers that
/// know the event kind should pass it.
pub fn from_feed_item(
    circle_id: &str,
    circle_name: &str,
    body: &str,
    media: &[&str],
    story: bool,
    author_name: &str,
) -> (String, BannerCopy) {
    let title = if author_name.is_empty() {
        "Someone".into()
    } else {
        author_name.to_string()
    };
    let copy = for_post(circle_id, circle_name, body, media, story);
    (title, copy)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reaction_never_says_posted() {
        let c = for_reaction("❤️", "family");
        assert_eq!(c.body, "Reacted ❤️ to your post");
        assert!(!c.body.to_lowercase().contains("posted"));
        assert_eq!(c.private_body, "Reacted to your post");
    }

    #[test]
    fn story_not_posted() {
        let c = for_post("family", "Family", "hi", &["vid_x"], true);
        assert_eq!(c.kind, kind::STORY);
        assert!(c.body.contains("story"));
    }

    #[test]
    fn dm_preview_private() {
        let c = for_post("dm:aa-bb", "x", "on my way", &[], false);
        assert_eq!(c.body, "on my way");
        assert_eq!(c.private_body, "Sent you a message");
    }

    #[test]
    fn display_body_levels() {
        let (use_name, b) = display_body("Family: hello", Some("Posted in your circle"), Some("post"), "full");
        assert!(use_name);
        assert_eq!(b, "Family: hello");
        let (_, b) = display_body("Family: hello", Some("Posted in your circle"), Some("post"), "private");
        assert_eq!(b, "Posted in your circle");
        let (use_name, b) = display_body("Family: hello", Some("Posted in your circle"), Some("post"), "minimal");
        assert!(!use_name);
        assert_eq!(b, "New activity");
    }
}
