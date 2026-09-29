//! Self-update: signed releases from GitHub, verified, installed atomically, health-checked,
//! rolled back on failure. See `relay/README.md` ▸ "Automatic updates" for the operator view.
//!
//! Flow of one check ([`Updater::run_once`]):
//!   1. GET the public release list (anonymous; see [`net`]).
//!   2. [`version::select_update`] — channel rules, never a downgrade, never a known-bad version.
//!   3. Download `<asset>` + `<asset>.sig` into `<data>/update/staging/`.
//!   4. [`sig::verify`] against the compiled-in [`sig::TRUSTED_KEYS`] — SHA-256 + asset name +
//!      version are all bound by the signature.
//!   5. Run `<new> version`: it must execute and report exactly the version we chose.
//!   6. Install ([`install`]) per the [`Plan`], record the pending install, ask the running relay
//!      to restart (exit code [`install::EXIT_RESTART`]) when something will bring it back.
//!
//! Logging: only this relay's own version events ("update X available / installed / rolled
//! back"). Never URLs with query data, never peers, never IPs.

pub mod install;
pub mod net;
pub mod sig;
pub mod version;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;
use std::time::Duration;

use anyhow::{anyhow, bail, Result};

use install::{Gate, Pending};
use version::{Candidate, Channel, Version};

/// This build's version: CI stamps the FULL release version (`1.2.0-rc.3`) through
/// `HAVEN_RELAY_BUILD_VERSION`; local builds report the crate version.
pub const VERSION: &str = match option_env!("HAVEN_RELAY_BUILD_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};

/// The target triple this binary was built for (set by build.rs).
pub const TARGET: &str = env!("HAVEN_RELAY_TARGET");

pub fn current_version() -> Version {
    Version::parse(VERSION).unwrap_or(Version { major: 0, minor: 0, patch: 0, rc: None })
}

/// Default GitHub repo the releases live in.
pub const DEFAULT_REPO: &str = "blaineam/haven";
/// Default time between checks.
pub const DEFAULT_INTERVAL: Duration = Duration::from_secs(6 * 3600);
/// How long a freshly-installed binary has to report healthy before it is rolled back.
pub const DEFAULT_HEALTH_WINDOW: Duration = Duration::from_secs(180);

// ── restart signal ────────────────────────────────────────────────────────────────────────────

static RESTART_REQUESTED: AtomicBool = AtomicBool::new(false);
fn restart_notify() -> &'static tokio::sync::Notify {
    static N: OnceLock<tokio::sync::Notify> = OnceLock::new();
    N.get_or_init(tokio::sync::Notify::new)
}

/// Ask the running relay to shut down cleanly and exit with [`install::EXIT_RESTART`].
pub fn request_restart() {
    RESTART_REQUESTED.store(true, Ordering::SeqCst);
    restart_notify().notify_one();
}

/// Resolves once a restart was requested.
pub async fn restart_requested() {
    if RESTART_REQUESTED.load(Ordering::SeqCst) {
        return;
    }
    restart_notify().notified().await;
}

// ── install plan ──────────────────────────────────────────────────────────────────────────────

/// How THIS process can apply an update.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Plan {
    /// Docker: install into `<data>/update/bin`; the entrypoint supervisor runs it.
    Volume,
    /// Replace the executable in place; `restart` = something will bring us back after we exit.
    InPlace { exe: PathBuf, restart: bool },
    /// Can't (or mustn't) install here — say "update available" only.
    NotifyOnly(String),
}

/// Inputs to [`decide_plan`], gathered from the environment (injected for tests).
#[derive(Clone, Debug, Default)]
pub struct PlanInputs {
    /// `HAVEN_RELAY_UPDATE_INSTALL` (volume | inplace | notify).
    pub install_env: Option<String>,
    /// Running under something that restarts us when we exit (Docker entrypoint, systemd, launchd).
    pub supervised: bool,
    pub exe: Option<PathBuf>,
    pub exe_dir_writable: bool,
    /// A manual `haven-relay update --now` (the operator restarts it themselves).
    pub manual: bool,
}

pub fn decide_plan(i: &PlanInputs) -> Plan {
    match i.install_env.as_deref().map(str::trim) {
        Some("volume") => return Plan::Volume,
        Some("notify") | Some("off") | Some("none") => {
            return Plan::NotifyOnly("HAVEN_RELAY_UPDATE_INSTALL=notify".into())
        }
        _ => {}
    }
    let Some(exe) = i.exe.clone() else {
        return Plan::NotifyOnly("can't locate this executable".into());
    };
    // A package manager owns these — replacing the file behind dpkg's back would desync it.
    let s = exe.to_string_lossy();
    if s.starts_with("/usr/bin/") || s.starts_with("/usr/sbin/") || s.starts_with("/bin/") || s.starts_with("/sbin/") {
        return Plan::NotifyOnly("installed by the system package manager — upgrade with apt".into());
    }
    if !i.exe_dir_writable {
        return Plan::NotifyOnly(format!("{} is not writable by this user", exe.parent().unwrap_or(&exe).display()));
    }
    if !i.supervised && !i.manual {
        return Plan::NotifyOnly(
            "not running under a service manager that would restart it (use `haven-relay service install`)".into(),
        );
    }
    Plan::InPlace { exe, restart: i.supervised && !i.manual }
}

/// Is something going to restart us when we exit?
pub fn detect_supervised() -> bool {
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    if env("HAVEN_RELAY_SUPERVISED").map(|v| v != "0").unwrap_or(false) {
        return true;
    }
    // systemd sets INVOCATION_ID for every service it starts (Restart=always in our units).
    if cfg!(target_os = "linux") && env("INVOCATION_ID").is_some() {
        return true;
    }
    // launchd sets XPC_SERVICE_NAME to the job label (our agent has KeepAlive).
    if cfg!(target_os = "macos") && env("XPC_SERVICE_NAME").as_deref() == Some("com.haven.relay") {
        return true;
    }
    false
}

pub fn gather_plan_inputs(manual: bool) -> PlanInputs {
    let exe = std::env::current_exe().ok().map(|p| std::fs::canonicalize(&p).unwrap_or(p));
    let exe_dir_writable = exe.as_deref().and_then(Path::parent).map(install::dir_writable).unwrap_or(false);
    PlanInputs {
        install_env: std::env::var("HAVEN_RELAY_UPDATE_INSTALL").ok().filter(|v| !v.trim().is_empty()),
        supervised: detect_supervised(),
        exe,
        exe_dir_writable,
        manual,
    }
}

// ── updater ───────────────────────────────────────────────────────────────────────────────────

/// Outcome of one check.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Disabled(String),
    UpToDate,
    /// Newer release exists but this install can't apply it (reason).
    Available { version: String, reason: String },
    Installed { version: String, restart: bool },
}

pub struct Updater {
    pub data_dir: PathBuf,
    pub channel: Channel,
    pub current: Version,
    /// `haven-relay-<target>` for this platform (None = no release asset exists for it).
    pub asset_name: Option<String>,
    pub keys: Vec<[u8; 32]>,
    pub list_url: String,
    /// Only for an explicit test/mirror URL override.
    pub allow_http: bool,
    /// The executable that is running now (for volume-mode "keep .prev?").
    pub running_exe: PathBuf,
}

impl Updater {
    /// The production updater for this build.
    pub fn from_env(data_dir: &Path, channel: Channel) -> Self {
        let url_override = std::env::var("HAVEN_RELAY_UPDATE_URL").ok().filter(|u| !u.trim().is_empty());
        let repo = std::env::var("HAVEN_RELAY_REPO").ok().filter(|r| !r.trim().is_empty()).unwrap_or_else(|| DEFAULT_REPO.into());
        let list_url = url_override
            .clone()
            .unwrap_or_else(|| format!("https://api.github.com/repos/{repo}/releases?per_page=30"));
        Updater {
            data_dir: data_dir.to_path_buf(),
            channel,
            current: current_version(),
            asset_name: version::asset_name_for_target(TARGET),
            keys: sig::trusted_keys(),
            allow_http: url_override.map(|u| u.starts_with("http://")).unwrap_or(false),
            list_url,
            running_exe: std::env::current_exe().unwrap_or_default(),
        }
    }

    fn dir(&self) -> PathBuf {
        install::update_dir(&self.data_dir)
    }

    /// Which release (if any) to move to.
    pub async fn check(&self, client: &reqwest::Client) -> Result<Option<Candidate>> {
        let Some(asset) = &self.asset_name else { return Ok(None) };
        let releases = net::fetch_releases(client, &self.list_url).await?;
        let bad = install::load_state(&self.dir()).bad_versions();
        Ok(version::select_update(&self.current, self.channel, &releases, &bad, asset))
    }

    /// Download + verify `cand` into a staged file inside `stage_dir` (which must be on the same
    /// filesystem as the install target). Marks the version bad if it is signed but broken.
    pub async fn fetch_verified(&self, client: &reqwest::Client, cand: &Candidate, stage_dir: &Path) -> Result<PathBuf> {
        if !self.allow_http {
            for a in [&cand.asset, &cand.sig] {
                if !a.url.starts_with("https://github.com/") {
                    bail!("refusing an asset URL outside github.com");
                }
            }
        }
        if cand.asset.size > net::MAX_ASSET_BYTES {
            bail!("release asset is implausibly large");
        }
        std::fs::create_dir_all(stage_dir)?;
        let v = cand.version.to_string();
        let sig_text = net::fetch_capped(client, &cand.sig.url, "application/octet-stream", net::MAX_SIG_BYTES).await?;
        let sig_text = String::from_utf8(sig_text).map_err(|_| anyhow!("signature is not text"))?;
        let part = stage_dir.join(format!(".haven-relay-{v}-{}.part", std::process::id()));
        let digest = match net::download_to(client, &cand.asset.url, &part, net::MAX_ASSET_BYTES).await {
            Ok(d) => d,
            Err(e) => {
                let _ = std::fs::remove_file(&part);
                return Err(e);
            }
        };
        if let Err(e) = sig::verify(&sig_text, &v, &cand.asset.name, &digest, &self.keys) {
            let _ = std::fs::remove_file(&part);
            bail!("update {v} REJECTED — {e}");
        }
        let staged = stage_dir.join(format!(".haven-relay-{v}.new"));
        std::fs::rename(&part, &staged)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
        }
        // It must actually run on this box and be the version it claims to be.
        match install::binary_version(&staged, Duration::from_secs(20)) {
            Some(got) if got == cand.version => Ok(staged),
            got => {
                let _ = std::fs::remove_file(&staged);
                let mut st = install::load_state(&self.dir());
                st.mark_bad(&v);
                let _ = install::save_state(&self.dir(), &st);
                bail!(
                    "update {v} is signed but {} — marked bad, will not retry",
                    match got {
                        Some(g) => format!("reports version {g}"),
                        None => "does not run on this machine".to_string(),
                    }
                )
            }
        }
    }

    /// One full check → (maybe) install.
    pub async fn run_once(&self, plan: &Plan) -> Result<Outcome> {
        if self.channel == Channel::Off {
            return Ok(Outcome::Disabled("auto-update is off".into()));
        }
        if self.asset_name.is_none() {
            return Ok(Outcome::Disabled(format!("no release builds exist for {TARGET}")));
        }
        let dir = self.dir();
        install::sweep_staging(&dir);
        if let Some(p) = install::load_state(&dir).pending {
            return Ok(Outcome::Disabled(format!("update {} is still on probation", p.version)));
        }
        let client = net::client(self.allow_http)?;
        let Some(cand) = self.check(&client).await? else { return Ok(Outcome::UpToDate) };
        let v = cand.version.to_string();
        let (stage_dir, exe) = match plan {
            Plan::NotifyOnly(reason) => {
                return Ok(Outcome::Available { version: v, reason: reason.clone() });
            }
            Plan::Volume => (install::staging_dir(&dir), None),
            Plan::InPlace { exe, .. } => (exe.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from(".")), Some(exe.clone())),
        };
        let staged = self.fetch_verified(&client, &cand, &stage_dir).await?;
        let cur = self.current.to_string();
        let pending: Pending = match &exe {
            None => install::install_volume(&dir, &staged, &v, &self.running_exe, &cur),
            Some(exe) => install::install_inplace(exe, &staged, &v, &cur),
        }
        .inspect_err(|_| {
            let _ = std::fs::remove_file(&staged);
        })?;
        let mut st = install::load_state(&dir);
        st.pending = Some(pending);
        install::save_state(&dir, &st)?;
        let restart = match plan {
            Plan::Volume => true,
            Plan::InPlace { restart, .. } => *restart,
            Plan::NotifyOnly(_) => false,
        };
        Ok(Outcome::Installed { version: v, restart })
    }
}

/// Log one outcome (version events only).
fn report(o: &Outcome, dir: &Path) {
    match o {
        Outcome::Installed { version, restart: true } => {
            println!("▸ auto-update: installed haven-relay {version} (signature verified) — restarting into it.")
        }
        Outcome::Installed { version, restart: false } => {
            println!("✓ installed haven-relay {version} (signature verified). Restart the relay to switch to it.")
        }
        Outcome::Available { version, reason } => {
            let mut st = install::load_state(dir);
            if st.notified.as_deref() != Some(version) {
                println!("ℹ haven-relay {version} is available (running {VERSION}); not auto-installing: {reason}.");
                st.notified = Some(version.clone());
                let _ = install::save_state(dir, &st);
            }
        }
        Outcome::UpToDate | Outcome::Disabled(_) => {}
    }
}

/// The background loop inside `haven-relay run`. First check after a randomized 10–30 min (never
/// during a crash loop or a probation window), then every `interval` + up to 1h of jitter so a
/// fleet of relays never hits GitHub in lockstep.
pub fn spawn_loop(data_dir: PathBuf, channel: Channel, interval: Duration) {
    if channel == Channel::Off {
        println!("  auto-update : off");
        return;
    }
    let plan = decide_plan(&gather_plan_inputs(false));
    match &plan {
        Plan::Volume => println!("  auto-update : {} channel (installs into the data volume; supervisor restarts)", channel.as_str()),
        Plan::InPlace { exe, .. } => println!("  auto-update : {} channel (replaces {} in place)", channel.as_str(), exe.display()),
        Plan::NotifyOnly(why) => println!("  auto-update : {} channel, notify only — {why}", channel.as_str()),
    }
    tokio::spawn(async move {
        use rand::Rng;
        let first = Duration::from_secs(rand::thread_rng().gen_range(600..1800));
        tokio::time::sleep(first).await;
        loop {
            let up = Updater::from_env(&data_dir, channel);
            match up.run_once(&plan).await {
                Ok(o) => {
                    report(&o, &install::update_dir(&data_dir));
                    if matches!(o, Outcome::Installed { restart: true, .. }) {
                        request_restart();
                        return;
                    }
                }
                // No detail beyond the error class — nothing here identifies anyone.
                Err(e) => eprintln!("⚠ auto-update check failed: {e:#}"),
            }
            let jitter = Duration::from_secs(rand::thread_rng().gen_range(0..3600));
            tokio::time::sleep(interval + jitter).await;
        }
    });
}

/// Startup half of the probation: call first thing in `run`. Returns whether this binary is on
/// probation. On too many failed starts it rolls back and EXITS with [`install::EXIT_RESTART`].
pub fn startup(data_dir: &Path) -> bool {
    let dir = install::update_dir(data_dir);
    match install::startup_gate(&dir, VERSION) {
        Gate::Normal => false,
        Gate::Probation(n) => {
            println!("▸ haven-relay {VERSION} is a fresh update (start {n}/{}) — health check pending.", install::MAX_ATTEMPTS);
            // Watchdog independent of the async runtime: if we are not proven healthy in time —
            // including a hang during startup — roll back and exit for the supervisor.
            let window = std::env::var("HAVEN_RELAY_UPDATE_HEALTH_SECS")
                .ok()
                .and_then(|s| s.parse().ok())
                .map(Duration::from_secs)
                .unwrap_or(DEFAULT_HEALTH_WINDOW);
            let dir2 = dir.clone();
            std::thread::spawn(move || {
                std::thread::sleep(window);
                if install::still_pending(&dir2, VERSION) {
                    if let Ok(Some(v)) = install::rollback_pending(&dir2) {
                        eprintln!("✗ update {v} did not pass its health check within {}s — rolled back.", window.as_secs());
                    }
                    std::process::exit(install::EXIT_RESTART);
                }
            });
            true
        }
        Gate::RolledBack(_) => std::process::exit(install::EXIT_RESTART),
    }
}

/// The first healthy report of a binary on probation keeps it.
pub fn confirm_healthy(data_dir: &Path) {
    if install::commit(&install::update_dir(data_dir), VERSION) {
        println!("✓ update to haven-relay {VERSION} confirmed healthy.");
    }
}

// ── CLI: `haven-relay update …` ───────────────────────────────────────────────────────────────

fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1).cloned())
}

/// `haven-relay update [--check | --now | --status | --rollback | --pick-bin PATH] [--channel C] [--data DIR]`
pub fn cli(args: &[String]) -> Result<()> {
    let data = PathBuf::from(arg_value(args, "--data").unwrap_or_else(crate::config::default_data_dir));
    let dir = install::update_dir(&data);
    let has = |f: &str| args.iter().any(|a| a == f);

    // Entrypoint helper: print which binary to run (the volume one only if strictly newer + not bad).
    if let Some(vol) = arg_value(args, "--pick-bin") {
        let vol = PathBuf::from(vol);
        let me = std::env::current_exe()?;
        let bad = install::load_state(&dir).bad_versions();
        let vv = if vol.is_file() { install::binary_version(&vol, Duration::from_secs(20)) } else { None };
        let pick = if install::prefer_volume(&current_version(), vv.as_ref(), &bad) { vol } else { me };
        println!("{}", pick.display());
        return Ok(());
    }
    if has("--rollback") {
        // Pending install first; otherwise (entrypoint safety net) drop the volume binary.
        match install::rollback_pending(&dir)? {
            Some(v) => println!("rolled back update {v} (marked bad)."),
            None => {
                let vol = install::volume_bin(&dir);
                if vol.exists() {
                    if let Some(v) = install::binary_version(&vol, Duration::from_secs(20)) {
                        let mut st = install::load_state(&dir);
                        st.mark_bad(&v.to_string());
                        install::save_state(&dir, &st)?;
                    }
                    let prev = vol.with_file_name(format!("{}.prev", vol.file_name().unwrap_or_default().to_string_lossy()));
                    if prev.exists() {
                        std::fs::rename(&prev, &vol)?;
                    } else {
                        std::fs::remove_file(&vol)?;
                    }
                    println!("removed the crashing self-updated binary; falling back.");
                } else {
                    println!("nothing to roll back.");
                }
            }
        }
        return Ok(());
    }
    if has("--status") {
        let st = install::load_state(&dir);
        println!("haven-relay {VERSION} ({TARGET})");
        println!("  last good : {}", st.last_good.as_deref().unwrap_or("-"));
        println!("  pending   : {}", st.pending.as_ref().map(|p| p.version.as_str()).unwrap_or("-"));
        println!("  bad       : {}", if st.bad.is_empty() { "-".to_string() } else { st.bad.join(", ") });
        return Ok(());
    }

    let channel = match arg_value(args, "--channel") {
        Some(c) => Channel::parse(&c).ok_or_else(|| anyhow!("--channel must be stable or rc"))?,
        None => crate::config::update_channel_from_env().unwrap_or(Channel::Stable),
    };
    let channel = if channel == Channel::Off { Channel::Stable } else { channel }; // explicit command
    let mut up = Updater::from_env(&data, channel);
    let plan = decide_plan(&gather_plan_inputs(true));
    // Docker: `docker exec … haven-relay update` runs the IMAGE binary, but the relay may already be
    // running a newer self-updated binary from the volume — compare against THAT.
    if plan == Plan::Volume {
        let vol = install::volume_bin(&dir);
        if let Some(vv) = install::binary_version(&vol, Duration::from_secs(20)) {
            if vv > up.current {
                up.current = vv;
                up.running_exe = vol;
            }
        }
    }
    let rt = tokio::runtime::Runtime::new()?;
    if has("--now") {
        let o = rt.block_on(up.run_once(&plan))?;
        match &o {
            Outcome::UpToDate => println!("haven-relay {} is up to date ({} channel).", up.current, channel.as_str()),
            Outcome::Disabled(why) => println!("not updating: {why}."),
            Outcome::Available { version, reason } => println!("haven-relay {version} is available but can't be installed here: {reason}."),
            Outcome::Installed { version, .. } => {
                println!("✓ installed haven-relay {version} (signature verified).");
                if plan == Plan::Volume {
                    println!("  restart the container to switch:  docker compose restart");
                } else {
                    println!("  restart the relay to switch (systemctl --user restart haven-relay / launchctl kickstart -k gui/$(id -u)/com.haven.relay).");
                }
            }
        }
        return Ok(());
    }
    // Default / --check: report only.
    let client = net::client(up.allow_http)?;
    match rt.block_on(up.check(&client))? {
        Some(c) => println!("update available: haven-relay {} → {} ({} channel). Install with `haven-relay update --now`.", up.current, c.version, channel.as_str()),
        None => println!("haven-relay {} is up to date ({} channel).", up.current, channel.as_str()),
    }
    Ok(())
}

#[cfg(test)]
mod tests;
