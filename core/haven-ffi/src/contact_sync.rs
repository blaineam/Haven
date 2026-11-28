//! The `contact:` records an account's own devices sync to each other: one set of rules for the
//! iPhone and Mac, Android, desktop and browser apps.
//!
//! The record is JSON, and each app used to write only its own field names, so none could read the
//! others': Apple `idHex, name, authoritativeName, nickname, verificationHex, avatarB64 (bare
//! base64), emoji, bio, link`; Android `id_hex, name, verify`; the desktop engine
//! `id_hex, name, verify_hex, emoji, avatar (data: URL), bio, link`. Worse, an app that could not
//! read a record did not have the contact, and published its removal.
//!
//! What is written now carries every spelling, so apps already installed read it too.

use serde_json::{Map, Value};

/// One contact, however its record spelled it.
#[derive(Clone, Debug, Default, PartialEq, uniffi::Record)]
pub struct ContactSyncCard {
    pub id_hex: String,
    /// The name to show: your nickname for them, else the name they signed, else the one they
    /// arrived with.
    pub name: String,
    pub verify_hex: String,
    pub emoji: String,
    /// A `data:` URL, or empty.
    pub avatar: String,
    pub bio: String,
    pub link: String,
}

fn object(record: &[u8]) -> Option<Map<String, Value>> {
    serde_json::from_slice(record).ok()
}

fn text<'a>(o: &'a Map<String, Value>, key: &str) -> &'a str {
    o.get(key).and_then(Value::as_str).unwrap_or("")
}

fn first(o: &Map<String, Value>, keys: &[&str]) -> String {
    keys.iter().map(|k| text(o, k)).find(|s| !s.is_empty()).unwrap_or("").to_string()
}

fn read(record: &[u8]) -> Option<ContactSyncCard> {
    let o = object(record)?;
    let id_hex = first(&o, &["idHex", "id_hex"]);
    if id_hex.is_empty() {
        return None;
    }
    let mut avatar = first(&o, &["avatar", "avatarB64"]);
    if !avatar.is_empty() && !avatar.starts_with("data:") {
        let kind = if avatar.starts_with("iVBOR") { "png" } else { "jpeg" };
        avatar = format!("data:image/{kind};base64,{avatar}");
    }
    Some(ContactSyncCard {
        id_hex,
        name: first(&o, &["nickname", "authoritativeName", "name"]),
        verify_hex: first(&o, &["verificationHex", "verify_hex", "verify"]),
        emoji: first(&o, &["emoji"]),
        avatar,
        bio: first(&o, &["bio"]),
        link: first(&o, &["link"]),
    })
}

/// `card` as a record every app decodes, keeping whatever else `previous` carried.
fn write(card: &ContactSyncCard, previous: Option<&[u8]>) -> Map<String, Value> {
    let mut o = previous.and_then(object).unwrap_or_default();
    let was = previous.and_then(read);
    let mut put = |k: &str, v: &str| {
        o.insert(k.to_string(), Value::String(v.to_string()));
    };
    put("idHex", &card.id_hex);
    put("id_hex", &card.id_hex);
    if was.as_ref().map_or(true, |w| w.name != card.name) {
        put("name", &card.name);
        if previous.is_some() {
            put("authoritativeName", &card.name);
        }
    } else if let Some(w) = &was {
        // Apple's decoder and Android's both need a `name`.
        if previous.and_then(object).is_some_and(|p| !p.contains_key("name")) {
            put("name", &w.name);
        }
    }
    if !card.verify_hex.is_empty() {
        for k in ["verificationHex", "verify_hex", "verify"] {
            put(k, &card.verify_hex);
        }
    } else if !o.contains_key("verify") {
        o.insert("verify".into(), Value::String(String::new()));
    }
    let mut put = |k: &str, v: &str| {
        o.insert(k.to_string(), Value::String(v.to_string()));
    };
    for (k, v) in [("emoji", &card.emoji), ("bio", &card.bio), ("link", &card.link), ("avatar", &card.avatar)] {
        if !v.is_empty() {
            put(k, v);
        }
    }
    if !card.avatar.is_empty() {
        let bare = card.avatar.split_once("base64,").map_or(card.avatar.as_str(), |(_, b)| b);
        put("avatarB64", bare);
    }
    o
}

fn bytes(o: &Map<String, Value>) -> Vec<u8> {
    serde_json::to_vec(o).unwrap_or_default()
}

/// Android's own record: three fields, no appearance.
fn android_only(record: &[u8]) -> bool {
    object(record).is_some_and(|o| o.contains_key("verify") && !o.contains_key("idHex"))
}

/// As Apple's app encodes its own contact: camelCase only.
fn apple_native(o: &Map<String, Value>) -> bool {
    o.contains_key("idHex") && !o.contains_key("id_hex")
}

/// The two names only an Apple app edits. Its own record leaving one out means it has none.
const APPLE_NAMES: [&str; 2] = ["nickname", "authoritativeName"];

/// Does this device know something about a contact that the shared record does not say? Only then
/// is it worth publishing: re-writing another app's spelling of the same contact would have two
/// devices overwrite each other for ever.
fn adds_to(card: &ContactSyncCard, base: &[u8]) -> bool {
    let Some(was) = read(base) else { return true };
    let newer = |mine: &str, theirs: &str| !mine.is_empty() && mine != theirs;
    if newer(&card.name, &was.name) || newer(&card.verify_hex, &was.verify_hex) {
        return true;
    }
    // An installed Android app re-writes any record that is not its own three fields, so a picture
    // is not added to one of its records: that would start the exchange above.
    !android_only(base)
        && (newer(&card.emoji, &was.emoji)
            || newer(&card.avatar, &was.avatar)
            || newer(&card.bio, &was.bio)
            || newer(&card.link, &was.link))
}

/// The contact a record describes, in whichever app's spelling. `None` if it is not one.
#[uniffi::export]
pub fn contact_sync_read(record: Vec<u8>) -> Option<ContactSyncCard> {
    read(&record)
}

/// `record` with every app's spelling filled in, for a decoder that knows only its own.
#[uniffi::export]
pub fn contact_sync_normalize(record: Vec<u8>) -> Option<Vec<u8>> {
    let card = read(&record)?;
    Some(bytes(&write(&card, Some(&record))))
}

/// What to stamp into the shared state for a contact this device publishes (`local`, in its own
/// spelling), given what the state already holds (`base`). `None`: leave it alone.
#[uniffi::export]
pub fn contact_sync_fold(local: Vec<u8>, base: Option<Vec<u8>>) -> Option<Vec<u8>> {
    if base.as_deref() == Some(local.as_slice()) {
        return None;
    }
    let (Some(card), Some(own)) = (read(&local), object(&local)) else { return Some(local) };
    let Some(base) = base else { return Some(bytes(&write(&card, Some(&local)))) };
    let apple = apple_native(&own);
    let renamed = apple
        && object(&base).is_some_and(|b| b.contains_key("idHex") && APPLE_NAMES.iter().any(|k| text(&own, k) != text(&b, k)));
    if !renamed && !adds_to(&card, &base) {
        return None;
    }
    let mut merged = write(&card, Some(&base));
    if apple {
        for k in APPLE_NAMES {
            match own.get(k) {
                Some(v) => merged.insert(k.to_string(), v.clone()),
                None => merged.remove(k),
            };
        }
        if let Some(name) = own.get("name") {
            merged.insert("name".into(), name.clone());
        }
    }
    let merged = bytes(&merged);
    (merged != base).then_some(merged)
}

/// May a contact missing from this device's list be published as removed? Not if the record cannot
/// be read: it never made it into the list, so its absence there says nothing.
#[uniffi::export]
pub fn contact_sync_may_tombstone(base: Option<Vec<u8>>) -> bool {
    base.as_deref().and_then(read).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What each app writes for one contact (Swift `JSONEncoder` leaves nil optionals out).
    const APPLE: &str = r#"{"idHex":"ab","name":"Hand Shake","authoritativeName":"Signed Name","verificationHex":"vv","avatarB64":"/9j/4AAQ","emoji":"🌊","bio":"hi","link":"https://example.org"}"#;
    const ANDROID: &str = r#"{"id_hex":"ab","name":"Signed Name","verify":"vv"}"#;
    const OLD_DESKTOP: &str = r#"{"id_hex":"ab","name":"Signed Name","verify_hex":"vv","emoji":"","avatar":"","bio":"","link":""}"#;

    fn v(b: &[u8]) -> Value {
        serde_json::from_slice(b).unwrap()
    }

    #[test]
    fn every_apps_record_reads_as_the_same_person() {
        for record in [APPLE, ANDROID, OLD_DESKTOP] {
            let c = contact_sync_read(record.into()).expect(record);
            assert_eq!((c.id_hex.as_str(), c.name.as_str(), c.verify_hex.as_str()), ("ab", "Signed Name", "vv"), "{record}");
        }
        assert_eq!(contact_sync_read(APPLE.into()).unwrap().avatar, "data:image/jpeg;base64,/9j/4AAQ");
    }

    #[test]
    fn a_normalized_record_has_what_every_installed_decoder_needs() {
        for record in [APPLE, ANDROID, OLD_DESKTOP] {
            let o = v(&contact_sync_normalize(record.into()).unwrap());
            for k in ["idHex", "id_hex", "name", "verify", "verify_hex", "verificationHex"] {
                assert!(o[k].is_string(), "{k} missing from {record}");
            }
        }
        // Apple's own names are not disturbed by normalizing its record.
        let o = v(&contact_sync_normalize(APPLE.into()).unwrap());
        assert_eq!((o["name"].as_str(), o["authoritativeName"].as_str()), (Some("Hand Shake"), Some("Signed Name")));
    }

    #[test]
    fn no_pair_of_apps_overwrites_each_other_over_a_spelling() {
        let all = [APPLE, ANDROID, OLD_DESKTOP];
        for local in all {
            for base in all {
                let published = contact_sync_fold(local.into(), None).unwrap();
                for held in [base.as_bytes().to_vec(), published] {
                    let first = contact_sync_fold(local.into(), Some(held.clone()));
                    // Whatever it stamps (if anything), the next pass has nothing more to say.
                    let after = first.unwrap_or(held);
                    assert_eq!(contact_sync_fold(local.into(), Some(after)), None, "{local} over {base}");
                }
            }
        }
        assert_eq!(contact_sync_fold(ANDROID.into(), Some(APPLE.into())), None);
        assert_eq!(contact_sync_fold(APPLE.into(), Some(ANDROID.into())), None, "pictures are not pushed into an installed Android app's record");
    }

    #[test]
    fn an_iphone_can_set_and_clear_a_nickname() {
        let shared = contact_sync_fold(APPLE.into(), None).unwrap();
        let nicked = APPLE.replace(r#""name":"Hand Shake","#, r#""name":"Hand Shake","nickname":"Mum","#);
        let with = contact_sync_fold(nicked.clone().into_bytes(), Some(shared)).expect("a nickname is news");
        assert_eq!(contact_sync_read(with.clone()).unwrap().name, "Mum");
        assert_eq!(contact_sync_fold(nicked.into_bytes(), Some(with.clone())), None);
        let cleared = contact_sync_fold(APPLE.into(), Some(with)).expect("so is taking it away");
        assert!(v(&cleared).get("nickname").is_none());
        assert_eq!(contact_sync_read(cleared).unwrap().name, "Signed Name");
    }

    #[test]
    fn a_rename_from_android_keeps_the_iphones_picture() {
        let shared = contact_sync_fold(APPLE.into(), None).unwrap();
        let renamed = ANDROID.replace("Signed Name", "New Name");
        let out = contact_sync_fold(renamed.into_bytes(), Some(shared)).expect("a rename is news");
        let c = contact_sync_read(out).unwrap();
        assert_eq!((c.name.as_str(), c.avatar.as_str(), c.emoji.as_str()), ("New Name", "data:image/jpeg;base64,/9j/4AAQ", "🌊"));
    }

    #[test]
    fn a_record_nobody_can_read_is_never_published_as_removed() {
        assert!(!contact_sync_may_tombstone(None));
        assert!(!contact_sync_may_tombstone(Some(br#"{"someFutureShape":1}"#.to_vec())));
        assert!(contact_sync_may_tombstone(Some(APPLE.into())) && contact_sync_may_tombstone(Some(ANDROID.into())));
    }
}
