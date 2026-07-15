variable "cloudflare_account_id" {
  description = "Cloudflare account that owns the haven-push Worker. Set via TF_VAR_cloudflare_account_id or terraform.tfvars (both gitignored)."
  type        = string
  sensitive   = true
}

variable "push_kv_namespace_id" {
  description = "Existing TOKENS namespace id, used only by the import block."
  type        = string
  # Not a secret: already committed in push/wrangler.toml, which stays the source of truth for the
  # binding. Duplicated here only so `tofu import` can find the namespace that already exists.
  default = "f75250adedb9471d88756ecab9f3bc16"
}

variable "push_kv_namespace_title" {
  description = "Display title of the TOKENS namespace as it exists in Cloudflare today."
  type        = string
  # wrangler names namespaces "<worker>-<binding>". UNVERIFIED against the live account — confirm
  # with `wrangler kv namespace list` before any apply; a wrong title plans a destroy/recreate,
  # which would drop every registered device token.
  default = "haven-push-TOKENS"
}
