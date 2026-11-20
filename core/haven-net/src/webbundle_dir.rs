//! Loading a built web client from disk into a [`WebBundle`] — for the HOSTS that serve one (the
//! desktop app, `haven-relay`). The proxy that serves it never reads the disk; a host reads it
//! once, here, and hands over the snapshot.

use std::path::Path;

use anyhow::{bail, Context, Result};

use crate::webbundle::WebBundle;

/// Read a built web client (`web-client/dist`) into a [`WebBundle`]. Every file under `dir` must be
/// a servable bundle file (plain relative name, known type) — an unexpected file is an error, not
/// something to skip, so a host never serves a directory it did not mean to.
pub fn load(dir: &Path) -> Result<WebBundle> {
    fn walk(root: &Path, dir: &Path, bundle: &mut WebBundle) -> Result<()> {
        for entry in std::fs::read_dir(dir).with_context(|| format!("read {}", dir.display()))? {
            let path = entry?.path();
            if path.is_dir() {
                walk(root, &path, bundle)?;
                continue;
            }
            let name = path.strip_prefix(root)?.to_string_lossy().replace('\\', "/");
            let bytes = std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
            if !bundle.insert(&name, bytes) {
                bail!(
                    "{name} is not a web client file (unexpected name or type) — is {} a web-client/dist build?",
                    root.display()
                );
            }
        }
        Ok(())
    }
    let mut bundle = WebBundle::new();
    walk(dir, dir, &mut bundle)?;
    if bundle.lookup("/app/").is_none() {
        bail!("{} has no index.html — build the web client first (web-client/build.sh)", dir.display());
    }
    Ok(bundle)
}

#[cfg(test)]
mod tests {
    use super::load;

    fn dir(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("haven-web-dir-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("pkg")).unwrap();
        d
    }

    #[test]
    fn loads_a_built_web_client_and_refuses_anything_else() {
        let d = dir("ok");
        std::fs::write(d.join("index.html"), "<!doctype html>").unwrap();
        std::fs::write(d.join("pkg/haven_web_bg.wasm"), [0u8, 97, 115, 109]).unwrap();
        let b = load(&d).expect("a dist directory loads");
        assert_eq!(b.len(), 2);
        assert!(b.lookup("/app/pkg/haven_web_bg.wasm").is_some());

        // A stray file that is not part of a web client makes the whole directory unacceptable.
        std::fs::write(d.join("id_rsa"), "secret").unwrap();
        let e = load(&d).unwrap_err().to_string();
        assert!(e.contains("id_rsa"), "{e}");
        let _ = std::fs::remove_dir_all(&d);

        let empty = dir("empty");
        assert!(load(&empty).unwrap_err().to_string().contains("index.html"));
        assert!(load(&empty.join("missing")).is_err());
        let _ = std::fs::remove_dir_all(&empty);
    }
}
