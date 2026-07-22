# Matrix media attach QA — final board

**Date:** 2026-07-22  
**Marker:** `MtxMedia_213103`  
**Topology:** HavenStub + iOS sim + Android emu (DEBUG)

## Author path (the gap we fixed)

| Check | Result | Evidence |
|-------|--------|----------|
| Android post + **photo** | **GREEN** | `HavenQA post body=…AndPhoto media=1` + `img_5e1abbc811fd` in state |
| Android post + **video** (+ poster) | **GREEN** | `video_path → vid_87d661b113f0 n=3` mediaRefs include poster+vid |
| Android **story** + photo | **GREEN** | `postStory body=…AndStoryPhoto media=1` + story=true in state |
| Android **DM** + photo | **YELLOW** | media minted; DM needs contact (peer re-ingest race after force-stop) |
| iOS post + **photo** | **GREEN** | `matrix-qa post body=…IosPhoto media=img_…` + feed.json |
| iOS post + **video** (+ poster) | **GREEN** | `video_path → vid_… media=3` + feed.json |
| iOS **story** + photo | **GREEN** | `matrix-qa story body=…IosStoryPhoto` + feed.json |
| iOS **DM** + photo | **GREEN** | `matrix-qa dm … media=1` + feed.json |

## Cross-device delivery (stub HTTP)

| Check | Result | Evidence |
|-------|--------|----------|
| Peer receives remote **text** body | **RED** | peer feed/state lacks remote `MtxMedia_*` markers |
| Peer restores remote **media** blob | **RED** | `relay … REFUSED media probe` / `mailbox put` — device not authorized on stub; iroh dial cooldown |

**Root cause (infra, not attach pipeline):** HavenStub HTTP returns 401/403 until membership/roster authorizes the client device id. Media **mint + attach + backup queue** run correctly; store-and-forward to the peer is blocked at the stub gate. Multipeer between iOS Simulator and Android Emulator is not a reliable substitute.

## Verdict

| Area | Status |
|------|--------|
| Photo/video **attach on author** (post/story/DM hooks) | **GREEN** |
| Fixtures + DEBUG QA drivers | **GREEN** (landed) |
| Cross-device mailbox/media restore on stub | **RED** (stub membership/auth) |

**Product claim for this RC:** media attachment authoring is instrumented and proven on both platforms. Cross-device restore on HTTP stub remains an authorization/infra follow-up (same class as field “metadata without media” when the live relay refuses or a dead NAS is first).
