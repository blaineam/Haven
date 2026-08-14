use std::path::Path;

fn main() {
    // Rebuild when the UI changes.
    //
    // `tauri_build::build()` emits rerun-if-changed for tauri.conf.json, capabilities/ and
    // binaries/ — but NOT for `frontendDist`. The UI is embedded into the binary at compile time,
    // so without this cargo sees no reason to rerun and a UI-only edit is silently dropped: the
    // build "succeeds" in seconds and launches the PREVIOUS interface. That cost a full debugging
    // cycle chasing a fix that was already correct on disk and simply never shipped.
    //
    // Cargo only stats the directory itself, which does not change when a file inside it is
    // edited, so every file has to be named individually.
    watch(Path::new("../ui"));

    tauri_build::build()
}

fn watch(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            watch(&path);
        } else {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
}
