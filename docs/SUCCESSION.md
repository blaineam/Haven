# Succession: could Haven live on without me?

> **I am not a lawyer, and neither is the tool that drafted this.** Everything in §1 is an
> **engineering reading of the license text in `LICENSE`** — what the words say, applied to what
> Haven actually does. It is not legal advice and it is not a settled conclusion. Estate law, IP
> assignment, and the enforceability of anything below vary by jurisdiction. **Confirm §1 and §4
> with an actual attorney** — specifically one who can look at both the license and your will.
> That conversation is short, cheap, and the single highest-leverage item in this document.

**The question that prompted this:** *"If I died tomorrow, could Haven live on easily? The source
is public — but would licensing prevent a successor?"*

**The short answer:** the source is not the problem, and the license is a bigger obstacle than it
looks. A successor could legally fork Haven and run it for free forever. They could **not** sell it,
and quite possibly could not ship it to the App Store at all, without a relicensing decision that
only the copyright holder — or their estate — can make. That decision is not currently written down
anywhere.

---

## 1. What the license actually permits

`LICENSE` is **GNU AGPL-3.0-or-later** (relicensed from PolyForm Noncommercial 2026-08-23 by the sole copyright holder). Copyright © Blaine Miller. Repo:
`github.com/blaineam/haven` (public). Read in full before writing this section; the relevant
clauses are quoted by name below.

### 1.1 What a successor clearly CAN do

| Action | Clause | Reading |
|---|---|---|
| Read, study, learn from the source | *Copyright License* | Yes. |
| Fork it | *Changes and New Works License* — "for any permitted purpose" | Yes, noncommercially. |
| Redistribute their fork | *Distribution License* | Yes, noncommercially, carrying the license text forward (*Notices*). |
| Run it as a hobby / personal project | *Personal Uses* — "hobby projects, amateur pursuits" | Yes, explicitly named. |
| Run it for a charity, school, or government body | *Noncommercial Organizations* | Yes, explicitly, "regardless of the source of funding". |
| Self-host relays, keep an existing install working | all of the above | Yes. |

So the **worst case is not that Haven dies.** Anyone can fork it and keep it alive for themselves,
their family, or a nonprofit. That floor is real and it is worth stating first.

### 1.2 What a successor clearly CANNOT do

**Sell it.** Haven is free on every store (since August 2026; it was a $9.99 one-time purchase
before that). Charging for a fork is a commercial purpose, and *Noncommercial Purposes* grants
only "any noncommercial purpose". There is no clause that permits it. A successor can keep a
fork free — which is what Haven is — but cannot turn it into a product.

**Sublicense or transfer the grant.** *No Other Rights* is explicit: "These terms do not allow you
to sublicense or transfer any of your licenses to anyone else." So a successor cannot re-grant
rights to a team, a company, or a foundation. Each person forks under the license individually.

### 1.3 The genuinely unclear part — free App Store distribution

This is the case that matters most and the license does not squarely answer it.

A successor shipping Haven **free** on the App Store, under their own developer account:

* *Personal Uses* permits "hobby projects, amateur pursuits... **without any anticipated commercial
  application**". A free app arguably qualifies.
* But shipping through the App Store requires a **$99/yr Apple Developer Program membership**, an
  entity relationship with Apple, and — if the account is an organization rather than an individual
  — probably falls under *Your company*, which the license treats as a commercial actor.
* (Historical, pre-relicense) PolyForm's own guidance treats "noncommercial" narrowly. A reasonable lawyer could read this
  either way.

**Engineering reading: do not rely on it.** A successor who wants App Store distribution should
assume they need a relicense, not that the current license covers them.

### 1.4 The thing that actually matters: copyright outlives the license

The license is a *grant to the world*. It is not the asset. The **copyright** is the asset, and on
death it passes as property — by will, or by intestacy law if there is no will.

Whoever inherits the copyright can **relicense Haven under anything they like**, including a
permissive or commercial license. That is the escape hatch from everything in §1.2 and §1.3.

Which means the real risk is not the license text at all. It is this:

> **Nothing currently identifies who inherits the copyright, or records the intent that they should
> relicense it so the project can continue.** Absent that, the copyright lands with whoever inherits
> the residual estate — possibly someone with no interest in software, who may not know they hold
> it, and from whom no successor maintainer can realistically obtain a relicense.

That is the actual single point of failure. It is fixed with a paragraph in a will, not with code.

### 1.5 One more trap: contributions

The README says "Contributions require a CLA/DCO." **There is no CLA or DCO file in the repository**
(no `CLA.md`, no `CONTRIBUTING.md`, no `NOTICE`). If outside contributions were ever merged without a
signed assignment, those contributors would hold copyright in their contributions and a future
relicense would need *their* agreement too.

**Checked, and this is good news:** `git log --format='%an <%ae>' | sort -u` returns exactly one
author — Blaine Miller \<blaine@wemiller.com\>. **Sole authorship, no third-party copyright in the
tree.** A relicense today needs one person's signature and nobody else's.

That is a window, not a permanent state. It closes the first time an outside PR is merged. Landing
the CLA/DCO *before* that happens is the cheap version of this problem; reconstructing consent from
past contributors is the expensive one.

---

## 2. What a successor cannot inherit from source alone

The source is public and complete. These are the things that are not in it.

| Asset | What breaks without it | Mitigation |
|---|---|---|
| **Apple Developer account + signing identity** | Cannot sign, cannot ship updates, cannot push to TestFlight. The **existing App Store listing, reviews, and install base are permanently unreachable.** Apple does not transfer accounts on death except via a documented legal-entity transfer; an individual account generally terminates. | None that preserves the listing. A successor ships a **new app** under **their own** account and existing users must migrate manually. Accept this and plan the migration path (see §5). |
| **App Store listing** | Same. Ratings, ranking, the URL people share — all gone. | Publish the new bundle id + a migration note on the website *before* it is needed. |
| **`wemiller.com` domain** | The marketing site, `relay/install.sh` (`curl https://wemiller.com/apps/haven/relay/install.sh \| sh`), and every deep link break. Relay installs silently stop working. | Registrar account in the estate inventory; ideally a second maintainer with registrar access. Also: **stop hardcoding the domain in install paths** — mirror `install.sh` to the GitHub release assets, which survive independently. |
| **Cloudflare account + `haven-push` Worker** | iOS push notifications die. Everything else keeps working. | Deliverable 2 of this branch. `push/worker.js` is in the repo; the endpoint is now re-pointable at runtime (Apple). See `docs/NOTIFICATIONS-FALLBACK.md`. |
| **APNs `.p8` auth key** | Cannot send pushes. | Not inheritable and **does not need to be** — a successor on their own developer account mints their own. Documented in `docs/NOTIFICATIONS-FALLBACK.md` §3. |
| **`TOKENS` KV namespace contents** | Every device's `token ↔ nodeId` mapping. Devices re-register on launch, so this self-heals over days. | Already the one thing codified in `infra/push_relay.tf` with `prevent_destroy`. Good. |
| **14 GitHub Actions secrets** | CI/CD, store autopublish, `SHARED_REPO_TOKEN` for the private tooling repos. | Names are documented in `docs/STORE-AUTOPUBLISH.md`; values are not (correctly). A successor regenerates them all against their own accounts. |
| **Private tooling repos** (Rocket, Soren, Knox, Monkr) | Release pipeline and QA workflows break; `qa.yml` 404s without `SHARED_REPO_TOKEN`. | These are **separate private repos not covered by Haven's license at all.** Either make them public, or document that a successor must replace the pipeline. This is an under-appreciated gap. |
| **The GitHub org/repo itself** | If the account lapses, the canonical repo and all release assets vanish — including the relay binaries the install script fetches. | Named GitHub successor (GitHub supports this), plus at least one full mirror held by someone else. |
| **Operational knowledge** | What to set, what breaks, why. | `docs/INFRA.md` is unusually honest and already covers most of this. It is the best asset in this table. |

**Not on this list, deliberately:** user data and keys. Haven is E2E encrypted and seed-based; there
is nothing to inherit and nothing to lose. That is by design and it is working.

---

## 3. What items 1 and 2 of this branch actually fix

This is the point of the branch, so it should be judged honestly.

| Failure | Before | After (this branch) |
|---|---|---|
| n0's DNS/pkarr lookup disappears | **Every install that can't hole-punch stops connecting.** Not fixable post-hoc. | Haven relays answer address lookups; n0 becomes a fallback. **Built and tested**, flag OFF. |
| n0's relay fleet disappears | Same. | **Designed, not built** — `RelayMode::Custom` + self-hosted `iroh-relay`. |
| Google STUN disappears | WebRTC calls stop traversing NAT. | **Not fixed.** Still hardcoded in three places (`docs/DECENTRALIZED-DISCOVERY.md` §1.2). |
| The push Worker disappears | Every install POSTs to a dead host forever; three app updates to redirect. | Endpoint re-pointable at runtime on Apple; push fully optional. **Android and desktop still hardcoded.** |
| The operator disappears | Relays are already self-hosted by users. | Unchanged — this was already good. |

So: one dependency removed in principle (address lookup), one made optional (push, on one platform),
two still open (DERP relays, STUN). The branch moves the needle; it does not finish the job.

---

## 4. Checklist — things to actually do

Ordered by leverage per unit of effort. The first three are worth more than everything else in this
document combined, and none of them is code.

### Do first (legal / custody — hours, not weeks)

1. **Talk to an attorney about the will.** Specifically: who inherits the Haven copyright, and can
   they be directed to relicense it permissively? This is the whole ballgame (§1.4).
2. **Decide the license question now, while you can.** Options, with tradeoffs:

   | Option | Effect | Cost |
   |---|---|---|
   | **Keep PolyForm** | Status quo. Nobody can sell it; App Store distribution is unclear; everything depends on the estate. | Free, but leaves §1.4 unresolved. |
   | **Add a "dead man's" forward grant** — a clause in `LICENSE`/`NOTICE` stating the software is *additionally* available under Apache-2.0 upon the licensor's death | Keeps the noncommercial protection while you're alive; guarantees a clean successor path. Unusual but expressible; **needs the attorney to draft the trigger**, since "upon death" must be verifiable. | Low. **Recommended if you want to keep noncommercial terms.** |
   | **Relicense now to Apache-2.0** | Fully solves succession. Anyone can fork, ship, and sell. | You give up exclusivity on selling it. |
   | **Relicense now to MPL-2.0** | File-level copyleft: forks must publish changes to Haven's own files, but can ship commercially. Middle ground. | Moderate. |
   | **AGPL-3.0** | Strong copyleft. **Do not choose this if App Store distribution matters** — Apple's ToS impose usage restrictions that conflict with the GPL family (this is why VLC was pulled). | Would break the thing you're trying to preserve. |
   | **Assign copyright to a foundation/entity** | Survives you institutionally. | Highest overhead; probably disproportionate for this project. |

3. **Write the CLA/DCO the README already claims exists** (§1.5), and audit existing history for
   outside contributions. Every day this waits, a future relicense gets marginally harder.

### Do soon (custody — a day)

4. **Name a GitHub successor** (GitHub supports this natively) and give at least one trusted person
   a full mirror of the repo including release assets.
5. **Inventory the registrar, Cloudflare, and Apple accounts** in whatever the estate documents are
   — including which email each is tied to.
6. **Put credentials in a password manager with an emergency-access contact** (1Password/Bitwarden
   both support this). Not the seed — Haven's own keys are deliberately unrecoverable and should
   stay that way. The *accounts*.
7. **Decide and document the private-tooling question** (Rocket/Soren/Knox/Monkr). Either make them
   public or write down that a successor must replace the pipeline. Right now a successor would
   discover this by watching CI 404.

### Do when convenient (engineering)

8. Finish deliverable 1: the `AddressLookup` shim, `RelayMode::Custom`, and a self-hosted
   `iroh-relay` (`docs/DECENTRALIZED-DISCOVERY.md` §4).
9. Make WebRTC ICE servers configurable; stop depending on Google STUN.
10. Port the push-endpoint override to Android and desktop; carry it in sealed circle state so an
    operator can redirect installed apps.
11. Mirror `relay/install.sh` to GitHub release assets so relay installation survives the domain.
12. Write `docs/RUNBOOK-SUCCESSOR.md`: "you have inherited this; here is how to ship a build." Much
    of the raw material is already in `docs/INFRA.md`, `docs/RELEASING.md`, and
    `docs/STORE-AUTOPUBLISH.md`.

---

## 5. The realistic successor story, end to end

Worth writing out, because it is less grim than it sounds — but only if §4 items 1–3 happen.

1. A successor forks the public repo. **Legal today, noncommercially.**
2. They enroll in the Apple Developer Program under their own name and mint their own signing
   identity and APNs key.
3. They change the bundle id (they must — they cannot use the original account's) and ship a **new**
   listing. The original listing is unrecoverable; existing users must find and install the new app.
4. They deploy `push/worker.js` to their own Cloudflare account and point clients at it — which
   **works without an app update**, on Apple, because of this branch.
5. Self-hosted relays keep working throughout. Users' data and identities are unaffected: the seed
   is on the device, not on any server.
6. **They cannot charge for it** — unless the copyright holder's estate relicenses.

Step 6 is where it stops, and step 6 is a §4 item 1–2 problem, not an engineering one.

---

## 6. Honest limits of this document

* §1 is an **engineering reading of license text**, not legal advice. It has not been reviewed by an
  attorney. Treat every conclusion in it as a hypothesis to confirm.
* The claim that Apple developer accounts generally cannot be inherited by an individual reflects
  the commonly documented position; **verify it with Apple directly** rather than trusting this
  document. Apple has a legal-entity transfer process whose applicability to an estate is exactly
  the kind of detail worth a phone call.
* The contribution-history audit (§1.5) has **not been performed** — the absence of a CLA file was
  checked; the commit history was not.
* No jurisdiction is assumed. Estate and IP law vary, and "the copyright passes as property" is a
  general statement, not a guarantee about any specific place.
