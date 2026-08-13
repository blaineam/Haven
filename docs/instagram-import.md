# Bringing your Instagram posts into Haven

Haven can import your Instagram back-catalogue — posts, stories and reels, with their captions,
their photos and videos, and their **original dates** — so your history lands in your circle in the
right order instead of in a heap at today's date.

Instagram does not offer an API for this. The only way to get your own posts out is to ask them for
an export, wait for them to build it, and then hand Haven the `.zip` they send you. This page is the
copy the in-app walkthrough follows.

---

## Step 1 — Ask Instagram for your export

Open **[accountscenter.instagram.com/info_and_permissions/dyi](https://accountscenter.instagram.com/info_and_permissions/dyi/)**

If that link moves, the path through the app is:

> Instagram → **☰ Menu** → **Accounts Center** → **Your information and permissions** →
> **Download your information** → **Download or transfer information**

Then:

1. Pick the account, and choose **Some of your information**.
2. Tick **Posts**, **Stories**, and **Reels**. (Ticking everything also works — Haven only reads
   those three and ignores the rest.)
3. Choose **Download to device**.
4. Set the options — **this is the part that matters**:

   | Option        | Choose            | Why |
   |---------------|-------------------|-----|
   | **Format**    | **JSON**          | **Required.** The HTML export is a website for humans, with no machine-readable data in it. Haven cannot read an HTML export at all, and there is no way to convert one. |
   | **Media quality** | **High**      | This is the actual quality of the photos and videos you import. Instagram defaults to a lower setting. |
   | **Date range**| **All time**      | Anything narrower silently leaves posts out. |

5. Submit the request.

> **Getting the format wrong is the one unrecoverable mistake.** If you pick HTML you have to
> request the whole export again and wait all over again. Check it says **JSON** before you submit.

## Step 2 — Wait

Instagram emails you when the file is ready. This usually takes a few hours, but it can take up to a
few days for a large account — it is entirely on their side and nothing in Haven speeds it up. You
can close Haven; the walkthrough remembers where you were.

The email contains a download link that **expires after a few days**, so download it when it lands.

## Step 3 — Come back and pick the file

Download the `.zip` (do **not** unzip it — Haven reads the archive directly), then in Haven:

> **You** → **Import from Instagram** → **Choose archive…**

Pick the `instagram-<username>-<date>-<code>.zip` file. Haven reads it on your device; the archive
is never uploaded anywhere.

Haven then shows you **exactly what it found** — how many posts, stories and reels, the date range,
and the total size — and nothing is published until you confirm.

---

## What gets imported

| From Instagram | Becomes in Haven |
|---|---|
| Post (single or carousel) | A post, with every photo/video in the album |
| Story | A story |
| Reel | A post with its video |
| Caption | The post's text |
| Original date | The post's date — history keeps its real order |
| Audio in a video | Plays as part of the video, exactly as it did on Instagram |

**Your circle is not notified.** Importing publishes silently: an import of several hundred posts
would otherwise fire several hundred notifications for content that is often years old. Members see
the posts in the feed in their proper place in history, with no banners.

## What does not come across

- **Drafts** — anything you never published stays unpublished.
- **Song titles.** Instagram's export does not include the name or artist of the music on a story or
  reel — only a broad genre, and only on some of them. The *music itself* is part of the video file,
  so your stories still play their song; there is just no song credit to display next to it. Nothing
  Haven can do changes this; the information is not in the file Instagram gives you.
- **Likes, comments, and followers** — Haven has no equivalent of a follower count, and other
  people's comments are theirs, not yours to republish.
- **Direct messages** — the export contains them, but importing other people's messages into a
  shared circle is not something Haven will do on their behalf.

## If something goes wrong

**"Haven can't read this archive."** Almost always an HTML export. Check the email — if the zip
contains `.html` files instead of a `your_instagram_activity/media/posts.json`, request a new export
in **JSON** format.

**Some photos look lower quality than you remember.** The export was built at a lower **media
quality** setting. Requesting a new export at **High** and importing again will bring the better
copies.

**The import is slow.** A large archive is well over a gigabyte of photos and video, all of which is
encrypted on your device as it is imported. It runs in the background — you can keep using Haven.
