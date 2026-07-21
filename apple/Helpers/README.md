# Helpers

Populated by `tools/fetch-cloudflared.sh` (CI / Xcode Cloud) — the binary itself is **not**
committed (size). `cloudflared.entitlements` **is** committed so the post-build phase can
sign the helper with App Sandbox inheritance.

## Updating cloudflared (no manual signing)

1. Bump `CLOUDFLARED_VERSION` in `core/haven-net/src/cfquicktunnel.rs` only.
2. Push. Xcode Cloud re-fetches and **codesigns automatically** every Archive.
3. Windows MSIX embeds the new exe; the Store re-signs on Partner Center upload.

You never run `codesign` / `signtool` on cloudflared yourself.

```sh
# Local macOS (optional — XCC does this for you):
tools/fetch-cloudflared.sh --apple-helpers
```
