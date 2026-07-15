# Infrastructure as code (OpenTofu)

Haven has almost no infrastructure, on purpose (see [DECISIONS](DECISIONS.md) D1 and
[OPERATING-COSTS](OPERATING-COSTS.md)). This document describes the little that exists, which
part of it is codified in `infra/`, and — more usefully — which part is still click-ops and why.

**Read this first:** `infra/` is one resource. That is not an oversight, it is the finding. If you
came here expecting a platform, the honest summary is that Haven's deployable surface is a single
Cloudflare Worker and a static site, and both already have a source of truth that isn't OpenTofu.

## What actually exists

| Thing | Where | Source of truth | Codified? |
|---|---|---|---|
| `haven-push` Worker script + vars + cron | Cloudflare Workers | `push/wrangler.toml` + `wrangler deploy` | No — wrangler owns it |
| `TOKENS` KV namespace | Cloudflare Workers KV | **nothing, until now** | ✅ `infra/push_relay.tf` |
| APNs secrets (`APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`) | Cloudflare Worker secrets | operator's memory + `push/README.md` | No — never |
| Marketing / invite-landing site | GitHub Pages | `.github/workflows/static.yml` | No — the workflow is the IaC |
| 14 GitHub Actions secrets | GitHub repo settings | `docs/STORE-AUTOPUBLISH.md` (names only) | No — never |
| `haven-relay` | users' own Pi/Mac/VPS | `install.sh`, [RELAY-AND-DEPLOY](RELAY-AND-DEPLOY.md) | No — **not our infra** |

## What's codified

Exactly one resource: the **`TOKENS` KV namespace** backing the blind APNs push relay
([NOTIFICATIONS](NOTIFICATIONS.md)).

It earns its place because it was the only piece of Haven's infrastructure with **no source of
truth at all**. It was created once by hand (`wrangler kv namespace create TOKENS`) and its id
pasted into `push/wrangler.toml`. That id records *what it is*, not *how to recreate it* — if the
Cloudflare account were lost, nothing in the repo said this namespace had to exist. Now something
does, and it carries `prevent_destroy`, because deleting it drops every device's
`token ↔ nodeId` mapping and clients only re-register on launch — pushes would die silently for
anyone who doesn't reopen the app.

The config uses an `import` block, so it **adopts** the live namespace rather than creating a
second one.

## What's deliberately not codified

- **The Worker script, vars, and cron trigger.** `wrangler.toml` already declares all of it and
  `wrangler deploy` already applies it. Adding `cloudflare_workers_script` would give the Worker
  two owners that fight on every deploy, and OpenTofu would need the bundled script content to do
  it. wrangler *is* the IaC here; it just isn't spelled OpenTofu.
- **Worker secrets and GitHub Actions secrets.** Both providers require the plaintext value to
  manage a secret, which would then sit in local state in the clear. The names are documented
  (`push/README.md`, `docs/STORE-AUTOPUBLISH.md`); the values stay in `wrangler secret put` and the
  GitHub UI. This is the correct trade, not a gap.
- **The GitHub repo itself.** `github_repository` manages the *whole* repository as one resource —
  importing a live repo with published releases risks a plan that reconfigures or destroys settings
  nobody meant to touch. Pages is already driven by `static.yml`. Not worth the blast radius.
- **`haven-relay` hosting.** A "stand up a VPS" module was considered and rejected. Haven's claim
  is that *we host nothing* — relays are run by users and volunteers. Shipping operator-shaped
  relay IaC would undercut a product promise to save a user one `curl | sh`.
- **A remote state backend.** It would cost money every month. See below.

## State

**Local state, on the operator's laptop.** A remote backend means a paid object store or a paid
TF Cloud seat, and Haven's mandate is $0 recurring beyond the $99/yr Apple fee. For one operator
and one resource, local state is the honest default — the failure mode of losing it is
`tofu import` with the id from `wrangler.toml`, which takes a minute.

State is gitignored: it contains the Cloudflare account id in plaintext. So is
`terraform.tfvars`.

## Running it

```sh
brew install opentofu
cd infra
cp terraform.tfvars.example terraform.tfvars   # fill in the account id
export CLOUDFLARE_API_TOKEN=...                # Account ▸ Workers KV Storage ▸ Edit
tofu init
tofu plan
```

`tofu plan` is read-only and safe. **Before the first `tofu apply`, verify the namespace title:**

```sh
wrangler kv namespace list
```

`push_kv_namespace_title` defaults to `haven-push-TOKENS` (wrangler's `<worker>-<binding>`
convention) but this has **never been checked against the live account**. Title is not updatable
in place — if it's wrong, the plan will show a **destroy and recreate**, which is exactly the
outcome `prevent_destroy` exists to block. If you see that plan, fix the variable, don't override
the guard.

## Is this worth it?

Marginally, and only for the one namespace. OpenTofu buys Haven a written record that the KV
namespace exists plus a guard against deleting it. It does not buy a reproducible environment,
because the parts that matter — the Worker code, the site, the secrets — are reproduced by
wrangler, GitHub Actions, and a human respectively, and should stay that way. If `infra/` ever
starts growing speculative modules for infrastructure Haven doesn't run, delete it; the
`wrangler kv namespace create` line in `push/README.md` was 90% as good.
