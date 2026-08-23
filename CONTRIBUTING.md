# Contributing to Haven

Haven is a private, end‑to‑end‑encrypted, serverless social network. Contributions are
welcome — the bar is that every change keeps the product trustworthy for the people whose
family photos ride on it.

## License and what it means for you

Haven is licensed under the **GNU AGPL‑3.0‑or‑later** (see [LICENSE](LICENSE)). In short:

- You may use, study, modify, and redistribute Haven freely — including commercially.
- If you distribute a modified Haven, **or run a modified Haven (including its relay) as a
  service others use over a network**, you must make your complete corresponding source
  available under the same license. Taking this code private for a paid product or hosted
  service without publishing your changes is exactly what this license forbids.
- Learning from the code, referencing techniques, and building unrelated things with what
  you learned needs no permission at all.
- The software comes **without warranty of any kind**; the copyright holder is not liable
  for how you use it (AGPL §15–16).

By submitting a contribution you agree it is licensed under AGPL‑3.0‑or‑later **with the additional permissions in [LICENSE-EXCEPTIONS.md](LICENSE-EXCEPTIONS.md)** (the app‑store distribution exception — the Signal/Nextcloud pattern that keeps GPL‑family apps listable on Apple's stores) and certify
the [Developer Certificate of Origin](https://developercertificate.org) — that you wrote
it or otherwise have the right to submit it.

Official Haven builds on the App Store, Google Play, and Microsoft Store are published by
the copyright holder. Third parties may not re‑list Haven or derivatives on app stores
under this license's terms without complying with it in full.

## How contributions are accepted

1. **Open an issue first** for anything larger than a typo — features and protocol changes
   especially. Haven's cryptography, delivery, and multi‑device semantics have sharp edges
   (see `docs/`), and an hour of discussion beats a rejected week of work.
2. **Every platform, same wave.** Haven ships feature‑parity across iOS, macOS, Android,
   and desktop (Windows/Linux). A feature PR that covers one platform should say how the
   others follow, or be scoped as an agreed platform‑specific fix.
3. **QA is the contract.** The e2e suite (`Scripts/qa-e2e-full.mjs`) drives a real
   four‑client fleet. A PR that changes behavior must extend the suite to cover it —
   the suite's matrices (calls: every caller × answerer; content: every author) exist
   because "works on the platform I tested" has shipped broken calls before.
4. **No silent scope.** Fixes that touch delivery, keying, or call signaling must describe
   the failure they fix in the commit message — the repo's history is its best
   documentation (`git log` is full of worked examples).
5. CI must be green: the full suite, every platform's build, and the release preflights.

## AI / LLM‑assisted contributions

AI‑assisted code is welcome **only** when the PR demonstrates that a human stands behind it:

- **You must have manually tested the change yourself** on at least one real platform
  target, and say so in the PR (what you ran, what you observed).
- **The PR must add the user stories it implements or fixes to the automated e2e suite**
  (`Scripts/qa-e2e-full.mjs` or the platform test targets) — an AI‑written change with no
  new automated coverage will be closed regardless of how plausible the diff looks.
- Un‑reviewed, un‑run "the model said this works" submissions are not contributions;
  they are review burden. Maintainers may close them without detailed feedback.

## Code of conduct

Be a decent person; see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Privacy‑hostile
proposals (telemetry, tracking, ad hooks, logging on the relay) are rejected on principle —
the relay's no‑logs promise is a commitment to members, not a default to toggle.
