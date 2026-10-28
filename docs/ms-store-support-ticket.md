# Partner Center support ticket — Haven Private Circles (9NKTFH1MF4LM)

**Where:** Partner Center → Help + support → New support request → Apps and games → Submission issues → "Pricing and availability / submission API".

**Subject:** Submission API commit always fails with InvalidPricingAvailabilitySettings (SalesUnsupportedWarning) — please clear legacy pricing/sales data on Haven's published submission

**Product:** Haven Private Circles — Store ID 9NKTFH1MF4LM — Seller ID 95100630 — MSIX app, Free, restricted markets.

## Problem

Every commit of a submission through the Microsoft Store submission API (`msstore` CLI v0.4.3 and the REST API behind it) fails at certification validation:

```
Submission Status = CommitFailed
InvalidParameterValue: Validation error: InvalidPricingAvailabilitySettings
SalesUnsupportedWarning: The sales resource is no longer supported. To view or edit the sales data for this submission, use the Dev Center dashboard.
```

This happens even for a **package-only submission created and committed without any update call** (`msstore publish <bundle> -id 9NKTFH1MF4LM`), i.e. we send no pricing, listing or availability data at all. So the invalid data is inherited from the app's last published submission (Submission 21, published 2026-10-15), not from anything we send.

## What we found

- A draft cloned from the last published submission shows **Pricing and availability = Unchanged** in the dashboard, yet API commit of it fails.
- After a draft is updated through the API (`submission update`, which must include a `Pricing` object — the CLI refuses an update without it, and the REST PUT answers 400 "Pricing data was not provided in the request"), the dashboard Pricing and availability page becomes **Incomplete** with "Valid price tier should be set for discounted price. Sale Pricing in France: Due to consumer laws, the Base price that shows in France must be the lowest price that you have charged in the last 30 days." The Sale pricing section then shows a phantom sale entry across all 235 markets with an empty discount value and every control disabled — there is no way to delete it in the dashboard.
- The pricing the API returns for the app: `PriceId: Free`, `TrialPeriod: NoFreeTrial`, `IsAdvancedPricingModel: false`, `MarketSpecificPricings: { CN, FR, LB, GF, PF, TF, EH: NotAvailable }`. The product is free; those markets are intentionally excluded.
- Microsoft's docs say the Sale resource is no longer supported through the submission API and that pricing is dashboard-only for apps on the newer pricing model.

## Submissions affected (all `CommitFailed`, none ever reached certification)

| Submission id | What it was |
|---|---|
| 1152921505702254472 | package + listings + pricing sent back unchanged (first attempt, 2026-10-28) |
| 1152921505702258493 | package-only; later PUT with listings (rejected) |
| 1152921505702258914 | fresh clone, full update with pricing returned unchanged |
| 1152921505702258982 | **package-only, clean clone of the published submission, no update call — still failed** |

## The offending data, identified in the dashboard (2026-10-28)

Pricing and availability → Sale pricing on a clean draft (cloned from published Submission 21, never touched by the API) contains one **expired legacy sale**: *Discount · Price · $4.99 · US · 235 markets · Offered to Everyone · Starts 07/18/2026 00:00 UTC · Ends 10/01/2026 00:00 UTC.* (Haven was a paid app when it was created; it is Free now.) Because the sale has ended, every field on it is disabled and the section has no delete/remove control — the only button is "New sale". There is no way for us to remove it in the dashboard, and the API treats it as the unsupported `sales` resource at commit.

**Exact failure mechanism (observed 2026-10-28 on submission 1152921505702259485):** on a clean portal-created draft the expired sale row reads `$4.99`. After the same draft has been saved or committed through the submission API, the row's price tier reads blank ("$ Select"), the row stays locked (sale has ended), and the dashboard shows "Valid price tier should be set for discounted price" — Pricing and availability becomes permanently Incomplete. A failed API commit also adds a second blank, editable sale row (that one has a Remove link; we removed it). The submission API's `Pricing` object (as returned by `msstore submission get`) contains `TrialPeriod`, `MarketSpecificPricings`, `PriceId` and `IsAdvancedPricingModel` — no sales field — so the sale cannot be sent back and its price tier is dropped.

## What we need from Microsoft

0. **Delete the expired $4.99 sale (Jul 18 – Oct 1, 2026, 235 markets) from Haven's published submission (Submission 21).** This is the most likely single cause.
1. Clear (or migrate to the current pricing model) the legacy **sales/pricing data on Haven's published submission (Submission 21)** so that API-created drafts validate and commit.
2. Confirm the supported way to commit a packaged-app update through the submission API (or `msstore`) for an app on the current pricing model — or whether such apps must be committed from the dashboard.
3. Confirm Free + excluded markets (CN, FR, LB, GF, PF, TF, EH) is representable in the current model and, if so, how the API should express it.

## Impact

Haven's Windows releases are automated from CI (`msstore` CLI). Every release is blocked at the final commit step and has to be completed by hand in the dashboard. The 2.1.0 package is waiting.
