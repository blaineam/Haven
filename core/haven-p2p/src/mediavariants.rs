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
}
