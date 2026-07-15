# The blind APNs push relay (push/worker.js, docs/NOTIFICATIONS.md).
#
# Only the KV namespace is described here. The Worker script itself is NOT an OpenTofu resource:
# `wrangler deploy` owns the code, and push/wrangler.toml already declares the script name, vars,
# cron trigger and KV binding. Modelling the script here would give it two owners that fight on
# every deploy. See docs/INFRA.md for the full "what's deliberately not here" list.

# Created by hand with `wrangler kv namespace create TOKENS` and never declared anywhere until now.
# This is the one piece of Haven's infrastructure whose existence had no source of truth: the id in
# wrangler.toml records what it is, not how to recreate it.
resource "cloudflare_workers_kv_namespace" "push_tokens" {
  account_id = var.cloudflare_account_id
  title      = var.push_kv_namespace_title

  # Destroying this drops every device's APNs token ↔ node id mapping, and clients only re-register
  # on launch — so pushes would silently die for anyone who doesn't reopen the app.
  lifecycle {
    prevent_destroy = true
  }
}

# Adopts the live namespace instead of creating a second one.
import {
  to = cloudflare_workers_kv_namespace.push_tokens
  id = "${nonsensitive(var.cloudflare_account_id)}/${var.push_kv_namespace_id}"
}
