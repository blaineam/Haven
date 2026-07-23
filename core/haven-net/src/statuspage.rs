//! Shared HTML for the relay's two human-visible pages — the path-proxy **front door**
//! (`path_router` answering `GET /` to a browser) and the **media port's** root/unknown-path
//! answer (`httprelay`). One CSS block, so the two answers look like one service instead of a
//! styled front door and a bare `<h1>` on the port behind it.

/// The one style block both pages share.
const CSS: &str = "\
 body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem;line-height:1.45;color:#111}\n\
 code,pre{font-size:.85rem;background:#f4f4f5;padding:.15rem .35rem;border-radius:4px}\n\
 pre{padding:1rem;overflow:auto}\n\
 .ok{color:#15803d;font-weight:600}";

/// The path-proxy front door: what a human sees opening a circle relay's public origin in a
/// browser. `status_json` is the proxy's route table (rendered verbatim in a `<pre>`), `bind`
/// its local listen address.
pub fn front_door_page(status_json: &str, bind: &str) -> String {
    // Escape for HTML text node (json is our own ASCII).
    let escaped = status_json.replace('&', "&amp;").replace('<', "&lt;");
    format!(
        r#"<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Haven relay</title>
<style>
{css}
</style></head><body>
<h1>Haven path proxy</h1>
<p class="ok">Front door is up.</p>
<p>This URL is the <strong>public HTTPS origin</strong> for a circle relay (media + iroh fabric + call hairpin).
It is not a website — Haven clients use signed API paths. Opening it in a browser only checks that the tunnel reaches this host.</p>
<p>Local bind: <code>{bind}</code></p>
<ul>
 <li><code>/k/*</code> <code>/l/*</code> <code>/t/*</code> — sealed media mailbox</li>
 <li><code>/relay</code> <code>/derp</code> <code>/ping</code> — iroh DERP fabric</li>
 <li><code>/webrtc/hairpin</code> — call media over free Cloudflare</li>
</ul>
<pre>{escaped}</pre>
</body></html>"#,
        css = CSS,
    )
}

/// The media port's answer to a browser (root / unknown path): point the human at the
/// path-proxy origin — this port only speaks the signed media verbs.
pub fn media_root_page() -> String {
    format!(
        r#"<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Haven media mailbox</title>
<style>
{css}
</style></head><body>
<h1>Haven media mailbox</h1>
<p>This is the <strong>media port</strong>: it serves sealed media over signed <code>/k/</code> <code>/l/</code> <code>/t/</code> paths and nothing human-readable.</p>
<p>Open the <strong>path-proxy origin</strong> (the relay's public URL, usually a tunnel to <code>:8675</code>) for a status page.</p>
</body></html>
"#,
        css = CSS,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pages_share_one_style_block() {
        let front = front_door_page(r#"{"service":"haven-path-proxy"}"#, "127.0.0.1:8675");
        assert!(front.contains("Front door is up"));
        assert!(front.contains("127.0.0.1:8675"));
        assert!(front.contains(CSS));
        let media = media_root_page();
        assert!(media.contains("media port"));
        assert!(media.contains(CSS));
    }

    #[test]
    fn front_door_escapes_json_for_html() {
        let f = front_door_page("<script>&", "b");
        assert!(f.contains("&lt;script>&amp;"));
        assert!(!f.contains("<script>"));
    }
}
