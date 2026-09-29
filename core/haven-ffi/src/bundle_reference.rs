//! TEST-ONLY golden reference: `epoch_sync_bundle_paged` exactly as it was before the bundle
//! builders stopped sealing under the engine lock (the whole build, sealing included, ran with the
//! guard held). Kept verbatim so a regression test can prove the lock-released version emits
//! byte-identical bundles — mailbox dedupe keys on those exact bytes. Do not "fix" this copy.

use super::*;

impl HavenSocial {
    pub(crate) fn epoch_sync_bundle_paged_reference(
        &self, circle_id: &str, mine_only: bool, limit: u32, head_only: bool, before_ms: u64,
    ) -> (Vec<Vec<u8>>, u64, u32, Vec<String>) {
        let mut st = self.state.lock().unwrap();
        let me_hex = hex(&st.me().node_id_bytes());
        let Some(idx) = st.circles.iter().position(|c| c.id == circle_id) else { return (vec![], 0, 0, vec![]) };
        // SENDER-expired content must never ride another bundle: a lapsed `retention_secs` is the
        // author's promise to the whole circle, so it purges here even if the app never calls
        // `purge_expired`. Viewer/circle retention is deliberately NOT applied — this path has no
        // viewer input, and a display preference must not destroy data it never promised to
        // delete. Wall clock is how `rotate_if_stale` keys its window too; the core has no
        // injected clock on this path.
        //
        // 48h RE-SEAL GRACE: the purge is evaluated against (now − 48h), NOT now. This path runs
        // on every epoch-head export — i.e. on the author's very next post and every launch — so
        // an exact-deadline purge deleted a 24h STORY from the author's engine the moment its
        // window lapsed, before the daily full-history backfill could ever re-deliver it to a
        // receiver that stalled (commit lag, offline). Display still hides expired content at the
        // exact deadline everywhere (`build_feed` is_expired + the app-driven purge_expired), so
        // the promise the viewer sees is unchanged — the grace only keeps the bytes exportable
        // long enough for late receivers to reconcile history.
        let grace_ms: u64 = 48 * 60 * 60 * 1000;
        purge_expired_from_circle(
            &mut st.circles[idx], None, None,
            now_secs().saturating_mul(1000).saturating_sub(grace_ms),
        );
        // TreeKEM tree wires (genesis commit + Welcomes for the creator; cached Remove commits) go on
        // the bundle regardless of the keying decision — a receiver needs them to build the tree AND
        // (M3) to derive the content epoch. Built BEFORE the flip decision so the tree exists when we
        // compute it. Plus my join ack (§7.2) and a re-broadcast of the verified admin grants (§4.3).
        // A FULL bundle (mine-only, unlimited, not head-only) is the one place a rotation is safe —
        // it re-seals my whole history under the new epoch in the same batch. Both the legacy
        // `rotate_if_stale` and the M5 PCS leaf-Update cadence gate on exactly this predicate.
        let full_bundle = !head_only && mine_only && limit == 0;
        let shadow_wires = shadow_emit_bundle(&mut st, idx, full_bundle);
        let join_wire = keying_emit_join(&mut st, idx);
        let admin_wires: Vec<Vec<u8>> =
            st.circles[idx].admin_grants.iter().map(|g| tagged(TAG_ADMIN_GRANT, g)).collect();
        // Upgrade offers ride the legacy circle's lane so its members see them. Only re-broadcast the
        // ones I authored: relaying someone else's would lend it my circulation, and an offer is a
        // claim to be judged, not a fact to spread.
        let my_acct = st.me().node_id_bytes();
        let upgrade_wires: Vec<Vec<u8>> = st.circles[idx]
            .upgrade_offers
            .iter()
            .filter(|w| CircleUpgrade::from_bytes(w).map(|u| u.creator == my_acct).unwrap_or(false))
            .map(|u| tagged(TAG_CIRCLE_UPGRADE, u))
            .collect();
        // THE KEYING FLIP / PARK DECISION (§4.5/§7.3), recomputed every bundle from verified state.
        // `Some(content_epoch)` ⇒ the circle is flipped: content seals under the tree-derived key and
        // the legacy KeyCommit STOPS. `None` ⇒ shadow or parked ⇒ legacy KeyCommit + sender-keys epoch.
        let mls_live = mls_refresh_keying(&mut st, idx);
        // PERIODIC forward-secrecy rotation (audit C2) — the trigger for `rotate_if_stale`. This is the
        // only safe place for it: a full bundle (`sync_envelopes` on the P2P path, `export_my_envelopes`
        // on the relay backfill) emits the new key commit AND re-seals my entire history under it in the
        // same batch, so no peer is ever left with an event whose key it can't obtain. Both are reached
        // by every client on a schedule, so no platform timer is needed and no client can forget to
        // rotate. head-only/limited bundles must NOT rotate — they'd publish an epoch without the
        // re-seal and strand relay-only readers until the next backfill. When the tree is LIVE, legacy
        // rotation is gated OFF (the tree drives the epoch); content keys come from `mls_live` instead.
        let (epoch, key) = match mls_live {
            Some(content_epoch) => {
                let key = st.circles[idx]
                    .my_epoch_keys
                    .get(&content_epoch)
                    .copied()
                    .expect("mls_refresh_keying populated my content key");
                (content_epoch, key)
            }
            None => {
                if full_bundle {
                    st.circles[idx].rotate_if_stale();
                } else {
                    st.circles[idx].ensure_epoch();
                }
                let e = st.circles[idx].my_epoch;
                let Some(k) = st.circles[idx].current_key() else { return (vec![], 0, 0, vec![]) };
                (e, k)
            }
        };
        let secret = st.circles[idx].my_circle_secret;
        let mut accounts = vec![st.me().clone()];
        accounts.extend(st.circles[idx].members.iter().cloned());
        // Expand each account member to its AUTHORIZED devices (mine + each contact's), so the circle's
        // key commit seals to every trusted device and NEVER a revoked one. Members whose device roster
        // we haven't learned fall back to their account key — pre-multidevice peers keep working.
        // Seed-drop S5 GATE: when retirement is ON *and* every member is affirmatively capable, the bare
        // per-member account key is dropped (seal to device bundles only), cutting off a revoked device
        // even from a seed-holding member. Default (retire=false) is byte-identical to the ungated call.
        let members = recipients_with_devices_gated(
            &accounts,
            &st.device_lists,
            &st.seed_drop_capable,
            st.retire_account_key,
        );
        // Seed-drop S3: author the commit + events under this DEVICE's key (`signer_of`) — BUT only once the
        // whole circle is affirmatively seed-drop-capable. This is the backwards-compat gate: a device-signed
        // envelope's sender is the device, which a pre-S1 peer can't chain to the account, so it would be
        // unreadable there (SEED-DROP-DESIGN §8/§4.2). Until every member advertises the S1 verifier (and we
        // hold their rosters), keep signing as the ACCOUNT — a fully-capable circle has no such peer. The S5
        // retirement gate above is a further, separately-flipped step on top of this. Seedless devices (no
        // account seed) can only reach this once their circle is capable, which is exactly the S4 precondition.
        let author_under_device = st.device.is_some()
            && circle_fully_seed_drop_capable(&accounts, &st.device_lists, &st.seed_drop_capable);
        let mut out: Vec<Vec<u8>> = Vec::new();
        // Share my OWN device roster so peers seal their content to all my devices (and never a revoked
        // one). Idempotent: a same-version roster is ignored on the receiver, so this can't rotation-storm.
        // A3: a primary re-signs its wire; a seedless device emits the primary-signed wire it holds VERBATIM
        // (trailer intact) — it cannot re-mint it.
        if let Some(wire) = st.own_roster_wire() {
            out.push(wire);
        }
        // Key commit: the hybrid KEM is random, so a re-seal for the SAME context yields new bytes
        // and the content-addressed mailbox would accumulate a copy per backfill. Reuse the cached
        // sealed commit while (epoch, key, secret, recipient devices) are unchanged.
        let commit_ctx: [u8; 32] = {
            let mut h = blake3::Hasher::new();
            h.update(b"haven-commit-ctx-v1");
            h.update(&epoch.to_le_bytes());
            h.update(&key);
            h.update(&secret);
            // The signer is part of the context: adopting a device key changes who signs the commit, so a
            // cached account-signed commit must not be reused after `use_device_identity`.
            h.update(&signer_of(&st, author_under_device).public().node_id_bytes());
            let mut ids: Vec<[u8; 32]> = members.iter().map(|m| m.node_id_bytes()).collect();
            ids.sort_unstable();
            for id in &ids {
                h.update(id);
            }
            *h.finalize().as_bytes()
        };
        // §4.5: when the tree is LIVE the KeyCommit STOPS — the commit IS the key distribution, and
        // content keys come from the tree. When shadow/parked, emit the KeyCommit exactly as today.
        if mls_live.is_none() {
            match &st.circles[idx].cached_commit {
                Some((ctx, bytes)) if *ctx == commit_ctx => out.push(bytes.clone()),
                _ => {
                    if let Ok(commit) = seal_key_commit(signer_of(&st, author_under_device), &members, circle_id, epoch, &key, &secret) {
                        let bytes = tagged(TAG_KEY_COMMIT, &commit.to_bytes());
                        st.circles[idx].cached_commit = Some((commit_ctx, bytes.clone()));
                        out.push(bytes);
                    }
                }
            }
        }
        // The tree wires + join ack + admin grants ride EVERY bundle (incl. head-only) so relay-only
        // readers and late joiners converge on the tree and the §7.2 gate; strictly additive.
        let append_tree = |out: &mut Vec<Vec<u8>>| {
            for w in &shadow_wires {
                out.push(w.clone());
            }
            if let Some(j) = &join_wire {
                out.push(j.clone());
            }
            for w in &admin_wires {
                out.push(w.clone());
            }
            for w in &upgrade_wires {
                out.push(w.clone());
            }
        };
        if head_only {
            append_tree(&mut out);
            return (out, 0, 0, vec![]); // roster + current key commit (or the tree) — no event re-seals
        }
        let mut picked: Vec<&Event> = st.circles[idx]
            .events
            .iter()
            .filter(|e| !mine_only || e.author == me_hex)
            // The paging cursor. Strictly older, so a receiver can pass the created_at of the
            // oldest post it holds and never be handed that same post back forever.
            .filter(|e| before_ms == 0 || e.created_at < before_ms)
            .collect();
        if limit > 0 {
            // "The most recent N" by TIME, not by position: the events vector is in arrival order
            // (imports and catch-up append), so a positional tail could skip older-but-late events
            // forever once the cursor moved past them. And the cut is extended over a timestamp tie:
            // the next page is strictly older than this page's oldest, so splitting a tie would drop
            // its other half for good.
            picked.sort_by_key(|e| e.created_at);
            let n = limit as usize;
            if picked.len() > n {
                let cut = picked[picked.len() - n].created_at;
                let start = picked.partition_point(|e| e.created_at < cut);
                picked = picked.split_off(start);
            }
        }
        let oldest = picked.iter().map(|e| e.created_at).min().unwrap_or(0);
        let count = picked.len() as u32;
        let events: Vec<Event> = picked.into_iter().cloned().collect();
        let mut media: Vec<String> = Vec::new();
        {
            for e in &events {
                let list = match &e.kind {
                    EventKind::Post { media, .. } | EventKind::Comment { media, .. } | EventKind::Edit { media, .. } => media,
                    _ => continue,
                };
                for m in list {
                    if !media.contains(m) { media.push(m.clone()); }
                }
            }
        }
        let compact = circle_is_compact_wire_capable(&st, idx);
        for e in &events {
            if let Ok(env) = seal_event_in_epoch(signer_of(&st, author_under_device), circle_id, epoch, &key, e) {
                out.push(tagged(TAG_EPOCH_EVENT, &env.to_bytes_gated(compact)));
            }
        }
        // Tree wires + join ack + admin grants (built up front). In M2/parked they ride ALONGSIDE the
        // KeyCommit (shadow); when LIVE they ARE the key distribution (§4.5). Additive either way.
        append_tree(&mut out);
        (out, oldest, count, media)
    }
}
