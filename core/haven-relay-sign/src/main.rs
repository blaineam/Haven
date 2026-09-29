//! `haven-relay-sign` — sign / verify haven-relay release assets.
//!
//!   haven-relay-sign keygen --out FILE             new key: base64 seed → FILE (0600), prints pubkey
//!   haven-relay-sign pubkey                        public key + key id of RELAY_SIGNING_KEY
//!   haven-relay-sign sign   --version V FILE...    write FILE.sig for each FILE
//!   haven-relay-sign verify --version V FILE...    check FILE.sig against the relay's trusted keys
//!
//! The private key is read from the `RELAY_SIGNING_KEY` environment variable (base64 of the 32-byte
//! Ed25519 seed) or `--key-file FILE` — never from a command-line argument, so it never lands in a
//! process listing or a CI log. `sign` REFUSES a key that the relay does not trust (its public key
//! is not in `TRUSTED_KEYS`), so a wrong or stale secret fails the release instead of shipping
//! signatures no relay will ever accept.

#[path = "../../haven-relay/src/update/sig.rs"]
#[allow(dead_code)]
mod sig;

use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("haven-relay-sign: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let cmd = args.first().map(String::as_str).unwrap_or("");
    let rest = &args[args.len().min(1)..];
    match cmd {
        "keygen" => keygen(rest),
        "pubkey" => {
            let seed = load_seed(rest)?;
            let pk = sig::public_key(&seed);
            println!("public key : {}", sig::to_hex(&pk));
            println!("key id     : {}", sig::key_id(&pk));
            Ok(())
        }
        "sign" => sign(rest),
        "verify" => verify(rest),
        _ => Err("usage: haven-relay-sign keygen --out FILE | pubkey | sign --version V FILE... | verify --version V FILE...".into()),
    }
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
}

/// Positional args (everything that isn't a known `--flag value` pair).
fn files(args: &[String]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() {
        if matches!(args[i].as_str(), "--version" | "--key-file" | "--out") {
            i += 2;
            continue;
        }
        if args[i].starts_with("--") {
            i += 1;
            continue;
        }
        out.push(PathBuf::from(&args[i]));
        i += 1;
    }
    out
}

fn decode_seed(b64: &str) -> Result<[u8; 32], String> {
    let raw = data_encoding::BASE64
        .decode(b64.trim().as_bytes())
        .map_err(|_| "signing key is not valid base64".to_string())?;
    raw.try_into().map_err(|_| "signing key must decode to exactly 32 bytes".to_string())
}

fn load_seed(args: &[String]) -> Result<[u8; 32], String> {
    if let Some(path) = flag(args, "--key-file") {
        let t = std::fs::read_to_string(&path).map_err(|e| format!("read {path}: {e}"))?;
        return decode_seed(&t);
    }
    match std::env::var("RELAY_SIGNING_KEY") {
        Ok(v) if !v.trim().is_empty() => decode_seed(&v),
        _ => Err("RELAY_SIGNING_KEY is not set (and no --key-file) — refusing to produce an unsigned release".into()),
    }
}

fn keygen(args: &[String]) -> Result<(), String> {
    use rand::RngCore;
    let out = flag(args, "--out").ok_or("keygen needs --out FILE")?;
    let out = Path::new(&out);
    if out.exists() {
        return Err(format!("{} already exists — refusing to overwrite a signing key", out.display()));
    }
    let mut seed = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut seed);
    write_private(out, &format!("{}\n", data_encoding::BASE64.encode(&seed)))?;
    let pk = sig::public_key(&seed);
    // Only PUBLIC material is printed.
    println!("wrote private seed to {} (mode 0600) — keep it secret, never commit it", out.display());
    println!("public key : {}", sig::to_hex(&pk));
    println!("key id     : {}", sig::key_id(&pk));
    Ok(())
}

#[cfg(unix)]
fn write_private(path: &Path, content: &str) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("create {}: {e}", path.display()))?;
    f.write_all(content.as_bytes()).map_err(|e| format!("write {}: {e}", path.display()))
}

#[cfg(not(unix))]
fn write_private(path: &Path, content: &str) -> Result<(), String> {
    std::fs::write(path, content).map_err(|e| format!("write {}: {e}", path.display()))
}

fn asset_name(path: &Path) -> Result<String, String> {
    path.file_name()
        .and_then(|n| n.to_str())
        .map(str::to_string)
        .ok_or_else(|| format!("bad file name: {}", path.display()))
}

fn sign(args: &[String]) -> Result<(), String> {
    let version = flag(args, "--version").ok_or("sign needs --version")?;
    let version = version.trim_start_matches("relay-v").trim_start_matches('v').to_string();
    let seed = load_seed(args)?;
    let pk = sig::public_key(&seed);
    let allow_untrusted = args.iter().any(|a| a == "--allow-untrusted");
    if !allow_untrusted && !sig::trusted_keys().contains(&pk) {
        return Err(format!(
            "the signing key (id {}) is not in haven-relay's TRUSTED_KEYS — relays would reject \
             these signatures. Fix the RELAY_SIGNING_KEY secret (or add the key to sig.rs first).",
            sig::key_id(&pk)
        ));
    }
    let list = files(args);
    if list.is_empty() {
        return Err("nothing to sign".into());
    }
    for f in list {
        let bytes = std::fs::read(&f).map_err(|e| format!("read {}: {e}", f.display()))?;
        let name = asset_name(&f)?;
        let text = sig::sign_asset(&seed, &version, &name, &bytes);
        let out = PathBuf::from(format!("{}.sig", f.display()));
        std::fs::write(&out, text).map_err(|e| format!("write {}: {e}", out.display()))?;
        println!("signed {name} ({version}) with key {}", sig::key_id(&pk));
    }
    Ok(())
}

fn verify(args: &[String]) -> Result<(), String> {
    let version = flag(args, "--version").ok_or("verify needs --version")?;
    let version = version.trim_start_matches("relay-v").trim_start_matches('v').to_string();
    let keys = sig::trusted_keys();
    let list = files(args);
    if list.is_empty() {
        return Err("nothing to verify".into());
    }
    for f in list {
        let bytes = std::fs::read(&f).map_err(|e| format!("read {}: {e}", f.display()))?;
        let name = asset_name(&f)?;
        let sig_path = PathBuf::from(format!("{}.sig", f.display()));
        let text = std::fs::read_to_string(&sig_path).map_err(|e| format!("read {}: {e}", sig_path.display()))?;
        let kid = sig::verify(&text, &version, &name, &sig::sha256(&bytes), &keys)
            .map_err(|e| format!("{name}: {e}"))?;
        println!("ok {name} ({version}) key {kid}");
    }
    Ok(())
}
