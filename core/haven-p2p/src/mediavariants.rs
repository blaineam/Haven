//! Wire-format helpers for video **poster** frames and optional **original** companions.
//! Cross-platform parity with Apple `MediaVariants.swift`.

/// `poster:<video>:<image>`
pub fn poster_marker(video: &str, poster: &str) -> String {
    format!("poster:{video}:{poster}")
}

/// `orig:<optimized>:<original>`
pub fn original_marker(optimized: &str, original: &str) -> String {
    format!("orig:{optimized}:{original}")
}

pub fn parse_poster(ref_: &str) -> Option<(&str, &str)> {
    let rest = ref_.strip_prefix("poster:")?;
    let colon = rest.rfind(':')?;
    let (v, p) = rest.split_at(colon);
    let p = &p[1..];
    if v.is_empty() || p.is_empty() {
        None
    } else {
        Some((v, p))
    }
}

pub fn parse_original(ref_: &str) -> Option<(&str, &str)> {
    let rest = ref_.strip_prefix("orig:")?;
    let colon = rest.rfind(':')?;
    let (o, orig) = rest.split_at(colon);
    let orig = &orig[1..];
    if o.is_empty() || orig.is_empty() {
        None
    } else {
        Some((o, orig))
    }
}

pub fn poster_for<'a>(video: &str, media: &'a [String]) -> Option<&'a str> {
    for r in media {
        if let Some((v, p)) = parse_poster(r) {
            if v == video {
                return Some(p);
            }
        }
    }
    None
}

/// Refs to show in a carousel (drop markers + original companions).
pub fn display_refs(media: &[String]) -> Vec<String> {
    let originals: std::collections::HashSet<&str> = media
        .iter()
        .filter_map(|r| parse_original(r).map(|(_, o)| o))
        .collect();
    media
        .iter()
        .filter(|r| parse_poster(r).is_none() && parse_original(r).is_none() && !originals.contains(r.as_str()))
        .cloned()
        .collect()
}

/// Super data saver: images/audio/files/posters only — never full videos or originals.
pub fn data_saver_prefetch_refs(media: &[String]) -> Vec<String> {
    let display = display_refs(media);
    let posters: std::collections::HashSet<&str> = media
        .iter()
        .filter_map(|r| parse_poster(r).map(|(_, p)| p))
        .collect();
    let mut out = Vec::new();
    for r in &display {
        if posters.contains(r.as_str())
            || r.starts_with("img_")
            || r.starts_with("i:")
            || r.starts_with("aud_")
            || r.starts_with("a:")
            || r.starts_with("file_")
        {
            out.push(r.clone());
        } else if let Some(p) = poster_for(r, media) {
            out.push(p.to_string());
        }
    }
    for p in posters {
        if !out.iter().any(|x| x == p) {
            out.push(p.to_string());
        }
    }
    out
}

/// Compose media list for a prepared video.
pub fn compose_video_media(poster: Option<&str>, optimized: &str, original: Option<&str>) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(p) = poster.filter(|s| !s.is_empty()) {
        out.push(p.to_string());
        out.push(poster_marker(optimized, p));
    }
    out.push(optimized.to_string());
    if let Some(o) = original.filter(|s| !s.is_empty() && *s != optimized) {
        out.push(o.to_string());
        out.push(original_marker(optimized, o));
    }
    out
}

/// Rewrite a media array after re-optimize (Apple/Android parity).
///
/// `swap`: old content ref → new content ref.
/// `posters`: **old** video ref → poster image ref to attach or replace.
pub fn rewrite_media(
    media: &[String],
    swap: &std::collections::HashMap<String, String>,
    posters: &std::collections::HashMap<String, String>,
) -> Vec<String> {
    let mut drop_poster_images = std::collections::HashSet::new();
    for old_video in posters.keys() {
        if let Some(p) = poster_for(old_video, media) {
            drop_poster_images.insert(p.to_string());
        }
    }
    let mut out = Vec::new();
    let mut emitted_poster_for = std::collections::HashSet::new();

    for ref_ in media {
        if let Some((v, p)) = parse_poster(ref_) {
            if posters.contains_key(v) {
                continue;
            }
            let nv = swap.get(v).map(|s| s.as_str()).unwrap_or(v);
            let np = swap.get(p).map(|s| s.as_str()).unwrap_or(p);
            out.push(poster_marker(nv, np));
            continue;
        }
        if let Some((opt, orig)) = parse_original(ref_) {
            let no = swap.get(opt).map(|s| s.as_str()).unwrap_or(opt);
            let nr = swap.get(orig).map(|s| s.as_str()).unwrap_or(orig);
            out.push(original_marker(no, nr));
            continue;
        }
        if drop_poster_images.contains(ref_) {
            continue;
        }
        let new_ref = swap.get(ref_).cloned().unwrap_or_else(|| ref_.clone());
        if let Some(poster_img) = posters.get(ref_) {
            if !emitted_poster_for.contains(ref_) {
                if !out.iter().any(|x| x == poster_img) {
                    out.push(poster_img.clone());
                }
                out.push(poster_marker(&new_ref, poster_img));
                out.push(new_ref);
                emitted_poster_for.insert(ref_.clone());
                continue;
            }
        }
        out.push(new_ref);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compose_and_display() {
        let media = compose_video_media(Some("img_p"), "vid_v", Some("vid_o"));
        let expected: Vec<String> = vec![
            "img_p".into(),
            "poster:vid_v:img_p".into(),
            "vid_v".into(),
            "vid_o".into(),
            "orig:vid_v:vid_o".into(),
        ];
        assert_eq!(media, expected);
        assert_eq!(
            display_refs(&media),
            vec![String::from("img_p"), String::from("vid_v")]
        );
        let pref = data_saver_prefetch_refs(&media);
        assert!(pref.iter().any(|x| x == "img_p"));
        assert!(!pref.iter().any(|x| x == "vid_v"));
        assert!(!pref.iter().any(|x| x == "vid_o"));
    }

    #[test]
    fn rewrite_adds_poster_only_without_touching_video() {
        let media = vec![String::from("vid_old"), String::from("img_still")];
        let swap = std::collections::HashMap::new();
        let mut posters = std::collections::HashMap::new();
        posters.insert(String::from("vid_old"), String::from("img_poster"));
        let out = rewrite_media(&media, &swap, &posters);
        let expected: Vec<String> = vec![
            String::from("img_poster"),
            String::from("poster:vid_old:img_poster"),
            String::from("vid_old"),
            String::from("img_still"),
        ];
        assert_eq!(out, expected);
    }

    #[test]
    fn rewrite_reencode_replaces_poster_and_video() {
        let media = compose_video_media(Some("img_oldp"), "vid_a", None);
        let mut swap = std::collections::HashMap::new();
        swap.insert(String::from("vid_a"), String::from("vid_b"));
        let mut posters = std::collections::HashMap::new();
        posters.insert(String::from("vid_a"), String::from("img_newp"));
        let out = rewrite_media(&media, &swap, &posters);
        let expected: Vec<String> = vec![
            String::from("img_newp"),
            String::from("poster:vid_b:img_newp"),
            String::from("vid_b"),
        ];
        assert_eq!(out, expected);
        // Old poster image must not linger.
        assert!(!out.iter().any(|x| x == "img_oldp"));
        assert!(!out.iter().any(|x| x == "vid_a"));
    }
}
