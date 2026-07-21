# Populated by `tools/fetch-cloudflared.sh` — not committed (size).

**Signing**

| Pipeline | What happens |
|---|---|
| Windows MSIX (`release.yml`) | Binary is **embedded** next to `Haven.exe`. Microsoft Store **re-signs** the package on Partner Center upload — no `signtool` here. |
| HavenMac / Xcode Cloud | Binary is fetched into `apple/Helpers/`; `embed-cloudflared.sh` **codesigns** with `EXPANDED_CODE_SIGN_IDENTITY`. |
| Linux / NSIS / MSI | Ships as Tauri `externalBin` (unsigned helper is fine outside the Store). |
