# Must match the `id` under [[kv_namespaces]] in push/wrangler.toml — this is the drift check.
output "push_kv_namespace_id" {
  description = "TOKENS namespace id for the haven-push Worker binding."
  value       = cloudflare_workers_kv_namespace.push_tokens.id
}
