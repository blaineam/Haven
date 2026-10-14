//! The song suggester's pure helpers (script detection, the POSIX-locale language), the MP4 audio
//! probe on real files, and the catalog calls — which under `HAVEN_NO_NET` must answer "nothing"
//! instead of reaching iTunes.

use super::*;
use crate::covtest_util::{tmp_paths, with_env};

fn mp4_box(name: &[u8; 4], body: &[u8]) -> Vec<u8> {
    let mut v = ((body.len() + 8) as u32).to_be_bytes().to_vec();
    v.extend_from_slice(name);
    v.extend_from_slice(body);
    v
}

/// A minimal ISO-BMFF clip whose tracks carry these handler types.
fn clip(handlers: &[&[u8; 4]]) -> Vec<u8> {
    let mut moov = Vec::new();
    for h in handlers {
        let mut hdlr = vec![0u8; 8]; // version/flags + pre_defined
        hdlr.extend_from_slice(*h);
        hdlr.extend_from_slice(&[0u8; 12]);
        let mdia = mp4_box(b"mdia", &mp4_box(b"hdlr", &hdlr));
        moov.extend(mp4_box(b"trak", &mdia));
    }
    let mut out = mp4_box(b"ftyp", b"isom\0\0\0\0isom");
    out.extend(mp4_box(b"free", &[0u8; 5]));
    out.extend(mp4_box(b"moov", &moov));
    out
}

#[test]
fn every_script_range_is_recognised_and_each_language_allows_its_own() {
    for (c, s) in [
        ('a', "latin"), ('é', "latin"), ('α', "greek"), ('ж', "cyrillic"), ('א', "hebrew"),
        ('ع', "arabic"), ('अ', "devanagari"), ('ก', "thai"), ('あ', "cjk"), ('漢', "cjk"), ('한', "hangul"),
    ] {
        assert_eq!(script_of(c), Some(s), "{c}");
    }
    assert_eq!(script_of('7'), None);
    assert_eq!(script_of('🙂'), None);

    for (lang, want) in [
        ("en", vec!["latin"]),
        ("ja", vec!["latin", "cjk"]),
        ("zh", vec!["latin", "cjk"]),
        ("ko", vec!["latin", "hangul", "cjk"]),
        ("ru", vec!["latin", "cyrillic"]),
        ("uk", vec!["latin", "cyrillic"]),
        ("el", vec!["latin", "greek"]),
        ("he", vec!["latin", "hebrew"]),
        ("ar", vec!["latin", "arabic"]),
        ("hi", vec!["latin", "devanagari"]),
        ("th", vec!["latin", "thai"]),
        ("xx", vec!["latin"]),
    ] {
        let got = scripts_for_language(lang);
        let mut want: Vec<&str> = want;
        want.sort();
        let mut have: Vec<&str> = got.iter().copied().collect();
        have.sort();
        assert_eq!(have, want, "{lang}");
    }
    // Judged on the share of letters, so one accented letter never disqualifies a title.
    let en = scripts_for_language("en");
    assert!(!uses_foreign_script("Chance Peña", &en));
    assert!(uses_foreign_script("愛しているよ", &en), "a CJK title is foreign to an English reader");
    assert!(!uses_foreign_script("愛しているよ", &scripts_for_language("ja")));
    assert!(!uses_foreign_script("ab", &en), "too few letters to judge");
}

#[test]
fn the_user_language_is_the_first_usable_posix_locale_variable() {
    fn all(v: &str) -> [(&str, &str); 4] {
        [("LC_ALL", v), ("LC_MESSAGES", v), ("LANG", v), ("LANGUAGE", v)]
    }
    with_env(&all("ja_JP.UTF-8"), || assert_eq!(user_language(), "ja"));
    with_env(&all("pt-BR"), || assert_eq!(user_language(), "pt"));
    // "C" / "POSIX" / empty are skipped; the next variable decides.
    with_env(&[("LC_ALL", "C"), ("LC_MESSAGES", "POSIX"), ("LANG", ""), ("LANGUAGE", "ko_KR")], || {
        assert_eq!(user_language(), "ko");
    });
    // Nothing usable falls back to the strictest answer.
    with_env(&all(""), || assert_eq!(user_language(), "en"));
    with_env(&all("x"), || assert_eq!(user_language(), "en"), );
    with_env(&all("de"), || assert!(user_scripts().contains("latin")));
}

#[test]
fn the_mp4_audio_probe_answers_from_the_handler_types_and_says_unknown_when_it_cannot_tell() {
    assert_eq!(mp4_has_audio_track(&clip(&[b"vide", b"soun"])), Some(true));
    assert_eq!(mp4_has_audio_track(&clip(&[b"vide"])), Some(false));
    assert_eq!(mp4_has_audio_track(&mp4_box(b"moov", b"")), None, "a moov with no track is unknown");
    assert_eq!(mp4_has_audio_track(b"not an mp4 at all"), None);

    let dir = tmp_paths().root;
    let write = |name: &str, bytes: &[u8]| {
        let p = dir.join(name);
        std::fs::write(&p, bytes).unwrap();
        p
    };
    assert_eq!(mp4_file_has_audio_track(&write("a.mp4", &clip(&[b"vide", b"soun"]))), Some(true));
    assert_eq!(mp4_file_has_audio_track(&write("v.mp4", &clip(&[b"vide"]))), Some(false));
    assert_eq!(mp4_file_has_audio_track(&dir.join("missing.mp4")), None);
    assert_eq!(mp4_file_has_audio_track(&write("junk.mp4", &[1, 2, 3])), None);
    // moov at the END after a big skipped box (the layout of a non-faststart file).
    let mut tail = mp4_box(b"mdat", &vec![0u8; 4096]);
    tail.extend(mp4_box(b"moov", &mp4_box(b"trak", &mp4_box(b"mdia", &mp4_box(b"hdlr", &[&[0u8; 8][..], b"soun", &[0u8; 12][..]].concat())))));
    assert_eq!(mp4_file_has_audio_track(&write("tail.mp4", &tail)), Some(true));
    // A box that claims to be smaller than its own header would loop forever: refuse it.
    assert_eq!(mp4_file_has_audio_track(&write("bad.mp4", &[0, 0, 0, 4, b'f', b'r', b'e', b'e', 0, 0, 0, 0])), None);
    // A 64-bit-size box (size field 1) is walked, and size 0 means "to the end of the file".
    let mut big = vec![0, 0, 0, 1];
    big.extend_from_slice(b"free");
    big.extend_from_slice(&(16u64 + 3).to_be_bytes());
    big.extend_from_slice(&[0, 0, 0]);
    big.extend(clip(&[b"soun"]));
    assert_eq!(mp4_file_has_audio_track(&write("big.mp4", &big)), Some(true));
    let mut to_end = vec![0, 0, 0, 0];
    to_end.extend_from_slice(b"mdat");
    to_end.extend_from_slice(&[0u8; 32]);
    assert_eq!(mp4_file_has_audio_track(&write("toend.mp4", &to_end)), None, "no moov anywhere is unknown");
    assert_eq!(mp4_has_audio_track(&big), Some(true), "the in-memory walk steps over a 64-bit box too");
}

#[tokio::test]
async fn offline_the_catalog_answers_nothing_instead_of_reaching_the_network() {
    assert_eq!(search("   ", 5).await, Some(Vec::new()));
    assert_eq!(search("beach", 5).await, Some(Vec::new()), "HAVEN_NO_NET: an empty result");
    assert!(lookup("12345").await.is_none());
    let none = HashSet::new();
    let got = suggestions(&["beach".to_string(), "sunset".to_string()], Some("rock"), 2024, 7, &none, 5).await;
    assert!(got.is_empty());
    assert!(song(&["beach".to_string()], None, 2024, 7, &none).await.is_none());
    assert!(ranked_by_era(Vec::new()).is_empty());
    assert_eq!(url_encode("a b&c é"), "a+b%26c+%C3%A9");
}
