#!/usr/bin/env python3
"""Prototype of Haven's Instagram archive parser.

Reads an unpacked (or zipped) Instagram JSON export and produces the exact list of
`postImported(circleId:body:media:music:story:createdAt:)` calls the importer would make.
Run against a real archive to validate the shape before implementing it three times.
"""
import json, os, sys, zipfile, collections, datetime

def load(z, name):
    try:
        with z.open(name) as f:
            return json.load(f)
    except KeyError:
        return None

def ig_text(s):
    """Instagram double-encodes UTF-8 as latin-1 in JSON exports (mojibake: 'PeÃ±a')."""
    if not isinstance(s, str):
        return s
    try:
        return s.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return s

Item = collections.namedtuple("Item", "kind created_at body media music_genre source")

def from_posts(d):
    """posts.json — the AUTHORITATIVE post record, NOT posts_1.json.

    posts_1.json looks like the obvious source but is a strict SUBSET: on a real archive it
    carried 851 media uris against posts.json's 979, so reading it silently drops 128 photos.
    posts.json also carries the `Draft` / `Published` flags, which is the only way to avoid
    republishing posts the user never actually published.

    Shape is the generic label_values form: each entry has a "Media" label holding the album.
    """
    def collect_media(o, acc):
        """Album members are NOT all under the top-level "Media" label — the 2nd..Nth photo of a
        carousel sits in a nested dict[] chain. Taking only the top-level label yielded exactly one
        photo per post (372 media instead of 979), silently truncating every album to its cover."""
        if isinstance(o, dict):
            if "uri" in o and isinstance(o["uri"], str):
                if o["uri"] not in {m["uri"] for m in acc}:
                    acc.append(o)
            for v in o.values():
                collect_media(v, acc)
        elif isinstance(o, list):
            for v in o:
                collect_media(v, acc)
        return acc

    out = []
    for entry in d or []:
        labels = {}
        for lv in entry.get("label_values", []):
            if lv.get("label") and lv.get("label") != "Media":
                labels[lv["label"]] = lv.get("value")
        # Drop subtitle sidecars — they are .srt/.vtt companions, not post media.
        media = [m for m in collect_media(entry, [])
                 if not m["uri"].endswith((".srt", ".vtt"))]
        if not media:
            continue
        if str(labels.get("Draft", "False")).lower() == "true":
            continue                      # never publish something they left as a draft
        # IG puts a single photo's caption on the media and an album's on the entry.
        body = ig_text(entry.get("title") or "") or ig_text(media[0].get("title") or "")
        created = entry.get("timestamp") or media[0].get("creation_timestamp")
        genres = [m.get("media_metadata", {}).get("video_metadata", {}).get("music_genre")
                  for m in media]
        out.append(Item("post", created, body, [m["uri"] for m in media],
                        next((g for g in genres if g), None), "posts.json"))
    return out

def from_stories(d):
    out = []
    for s in (d or {}).get("ig_stories", []):
        vm = s.get("media_metadata", {}).get("video_metadata", {})
        out.append(Item("story", s.get("creation_timestamp"), ig_text(s.get("title") or ""),
                        [s["uri"]], vm.get("music_genre"), "stories.json"))
    return out

def from_reels(d):
    out = []
    for r in (d or {}).get("ig_reels_media", []):
        for m in r.get("media", []):
            vm = m.get("media_metadata", {}).get("video_metadata", {})
            out.append(Item("reel", m.get("creation_timestamp"), ig_text(m.get("title") or ""),
                            [m["uri"]], vm.get("music_genre"), "reels.json"))
    return out

def main(path):
    z = zipfile.ZipFile(path)
    names = set(z.namelist())
    items = []
    items += from_posts(load(z, "your_instagram_activity/media/posts.json"))
    items += from_stories(load(z, "your_instagram_activity/media/stories.json"))
    items += from_reels(load(z, "your_instagram_activity/media/reels.json"))
    items = [i for i in items if i.created_at]
    items.sort(key=lambda i: i.created_at)

    missing = [u for i in items for u in i.media if u not in names]
    total_bytes = sum(z.getinfo(u).file_size for i in items for u in i.media if u in names)
    with_music = [i for i in items if i.music_genre]
    with_caption = [i for i in items if i.body.strip()]

    print(f"ARCHIVE: {os.path.basename(path)}")
    print(f"  entries in zip     : {len(names)}")
    print(f"  importable items   : {len(items)}")
    for k, c in collections.Counter(i.kind for i in items).most_common():
        print(f"      {k:8s}: {c}")
    print(f"  media files        : {sum(len(i.media) for i in items)}  ({total_bytes/1e9:.2f} GB)")
    print(f"  MISSING media refs : {len(missing)}")
    print(f"  with a caption     : {len(with_caption)}")
    print(f"  with music_genre   : {len(with_music)}")
    span = (datetime.datetime.fromtimestamp(items[0].created_at),
            datetime.datetime.fromtimestamp(items[-1].created_at))
    print(f"  date span          : {span[0]:%Y-%m-%d} -> {span[1]:%Y-%m-%d}")

    print("\n--- first 3 postImported() calls ---")
    for i in items[:3]:
        show(i)
    print("\n--- 3 most recent ---")
    for i in items[-3:]:
        show(i)
    print("\n--- 2 with music ---")
    for i in with_music[:2]:
        show(i)
    print("\n--- longest caption (mojibake check) ---")
    show(max(items, key=lambda i: len(i.body)))

def show(i):
    ts = datetime.datetime.fromtimestamp(i.created_at)
    body = i.body.replace("\n", " ⏎ ")
    print(f"  [{i.kind}] createdAt={i.created_at*1000}  ({ts:%Y-%m-%d %H:%M})")
    print(f"     body : {body[:110]!r}{'…' if len(body) > 110 else ''}")
    print(f"     media: {i.media}")
    if i.music_genre:
        print(f"     genre: {i.music_genre}")

if __name__ == "__main__":
    main(sys.argv[1])
