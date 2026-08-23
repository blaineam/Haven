# US export compliance + where Haven is (and isn't) sold

Haven ships **real end-to-end, post-quantum encryption**, and that has two regulatory
consequences: Apple's export-compliance questionnaire, and a short list of territories
Haven deliberately does not distribute to. Both are policy, both are automated, and both
are audited by one command:

```sh
node _shared/rocket/rocket.mjs compliance Haven     # the audit (read-only)
node _shared/rocket/rocket.mjs territories Haven    # availability vs. policy (read-only; --apply writes)
```

## The export-compliance answer

`Info.plist` (both targets, set in `apple/project.yml`): **`ITSAppUsesNonExemptEncryption = false`**.

That is the "qualifies for an exemption" answer — Haven's cryptography is standard, published
algorithms (hybrid X25519 + ML-KEM, AES-GCM, Ed25519/ML-DSA) in a mass-market app. With the
answer baked into the binary, every Xcode Cloud upload is auto-compliant: no per-build
"Missing Compliance" prompt, no ASC questionnaire, and `apple-store.yml` never has to wait on
it. (If a build ever arrives with the flag unset, the auto-submit script answers *exempt* on the
build itself, matching the plist.)

There is a leftover `CREATED` App Encryption Declaration on the ASC record from an earlier,
non-exempt attempt (it says "available on the French store"). It is inert — it is attached to no
build and the API can neither finish nor delete it. `rocket compliance Haven` reports it; ignore
it.

## Territories

| Territory | Available | Why |
|---|---|---|
| **France** | **no** | French law (ANSSI) wants its own declaration for apps shipping encryption, and Apple asks "available in France?" on the non-exempt path. Out, so the question is moot. |
| **China (mainland)** | **no** | Any app needs an ICP filing number to be sold there; Apple flags the listing `MISSING_GRN` without one. |
| **EU (27)** | **yes** | Haven is **free with no in-app purchases**, so it stays in the EU under the Digital Services Act without a trader declaration. (The paid apps in the portfolio are out of the EU for exactly that reason — see `_shared/rocket/docs/compliance.md`.) |
| everything else (173 storefronts) | yes | |

The policy lives in `appstore-metadata.md`:

```md
## availability
exclude: france, china
new_territories: yes

## price
free
```

and `rocket territories Haven` diffs App Store Connect against it (`--apply` writes; the write is
per-territory `PATCH /v1/territoryAvailabilities/{id}` and is read back before the command says
✓). `Scripts/asc-availability.mjs` is the older single-territory version of the same thing.

**Going free (August 2026).** The App Store price is set from the same file with
`rocket price Haven --apply`. Google Play's price is a one-way, console-only change (a free app
can never be made paid again; there is no API) and the Microsoft Store price is a Partner Center
submission — both are one-time by-hand steps, noted in `docs/STORE-AUTOPUBLISH.md`.

## If Haven ever goes non-exempt again

Switching the plist to `true` means every build needs an **APPROVED** App Encryption Declaration
attached. The first one must be completed in App Store Connect → App Information → App
Encryption Documentation (uses encryption: yes · exemption: no · standard algorithms: yes ·
mass-market, ECCN 5D992.c / License Exception ENC); after that `rocket compliance Haven
--attach` attaches it to each new build. The annual BIS/NSA self-classification report and the
one-time open-source notification (`Scripts/export-compliance.mjs` generates both) become due
again on that path. None of that applies while the answer is *exempt*.
