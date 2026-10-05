//! `haven-relay service install` / `uninstall` — wire the relay up to **auto-restart on login**
//! on the current OS, using only built-in OS mechanisms (no extra deps):
//!   • Linux   → a systemd *user* unit (+ `loginctl enable-linger`), or a crontab `@reboot` fallback
//!   • macOS   → a launchd LaunchAgent (`RunAtLoad` + `KeepAlive`)
//!   • Windows → a Scheduled Task at logon (`schtasks /SC ONLOGON`)
//!
//! The installed service runs `haven-relay run` (no args) which reuses the saved circle link,
//! so attach the relay to a circle once (`haven-relay run --link <code>`) before installing.

use std::path::PathBuf;
use std::process::Command;

use anyhow::{anyhow, Result};

#[allow(dead_code)] // used on macOS
const LABEL: &str = "com.haven.relay";
#[allow(dead_code)] // used on Windows
const TASK: &str = "HavenRelay";

fn exe() -> Result<PathBuf> {
    std::env::current_exe().map_err(|e| anyhow!("can't find my own path: {e}"))
}

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("no HOME directory"))
}

pub fn install(extra: &[String]) -> Result<()> {
    let exe = exe()?;
    // Only start the service right away if the relay is ALREADY linked to a circle; otherwise just
    // register it (it'll start on the next login/reboot, by which time the user has linked) so we
    // don't spin a restart loop logging "no saved circle link".
    let linked = is_linked(extra);
    if !linked {
        println!("ℹ Not linked to a circle yet — registered the service; it starts serving after you run");
        println!("  `haven-relay run --link <code>{}` once (or on the next login).",
                 data_flag_hint(extra));
    }
    #[cfg(target_os = "linux")]
    return linux_install(&exe, extra, linked);
    #[cfg(target_os = "macos")]
    return macos_install(&exe, extra, linked);
    #[cfg(target_os = "windows")]
    return windows_install(&exe, extra, linked);
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    Err(anyhow!("auto-start isn't supported on this OS yet — run `haven-relay run` from your own startup mechanism"))
}

fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1).cloned())
}

/// The data dir the relay will use (a custom `--data` storage path, or the default).
fn data_dir(extra: &[String]) -> PathBuf {
    arg_value(extra, "--data")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(crate::config::default_data_dir()))
}

/// Whether a circle link is already saved (so the service can start serving immediately).
fn is_linked(extra: &[String]) -> bool {
    data_dir(extra).join("link.json").exists()
}

fn data_flag_hint(extra: &[String]) -> String {
    arg_value(extra, "--data").map(|d| format!(" --data {d}")).unwrap_or_default()
}

/// `run` plus the operator's passthrough flags, double-quoted for a shell/systemd command line.
#[allow(dead_code)] // used on Linux + Windows; macOS uses a plist array instead
fn run_cmdline(exe: &std::path::Path, extra: &[String]) -> String {
    let mut s = format!("\"{}\" run", exe.display());
    for a in extra {
        s.push(' ');
        s.push('"');
        s.push_str(a);
        s.push('"');
    }
    s
}

pub fn uninstall() -> Result<()> {
    #[cfg(target_os = "linux")]
    return linux_uninstall();
    #[cfg(target_os = "macos")]
    return macos_uninstall();
    #[cfg(target_os = "windows")]
    return windows_uninstall();
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    Err(anyhow!("nothing to uninstall on this OS"))
}

// ── Linux: systemd user unit (fallback: crontab @reboot) ─────────────────────────────────
#[cfg(target_os = "linux")]
fn linux_install(exe: &std::path::Path, extra: &[String], linked: bool) -> Result<()> {
    let unit_dir = home()?.join(".config/systemd/user");
    let has_systemd = Command::new("systemctl").arg("--user").arg("--version").output().map(|o| o.status.success()).unwrap_or(false);
    if has_systemd {
        std::fs::create_dir_all(&unit_dir)?;
        let unit = format!(
            "[Unit]\nDescription=Haven relay (always-on circle mailbox, ciphertext only)\nAfter=network-online.target\nWants=network-online.target\n\n\
             [Service]\nType=simple\nExecStart={}\nRestart=always\nRestartSec=5\n\n\
             [Install]\nWantedBy=default.target\n",
            run_cmdline(exe, extra)
        );
        std::fs::write(unit_dir.join("haven-relay.service"), unit)?;
        // Keep it running after logout, reload, enable (+ start now only if already linked).
        let _ = Command::new("loginctl").arg("enable-linger").arg(whoami()).status();
        run(Command::new("systemctl").args(["--user", "daemon-reload"]))?;
        let enable_args: &[&str] = if linked {
            &["--user", "enable", "--now", "haven-relay"]
        } else {
            &["--user", "enable", "haven-relay"]
        };
        run(Command::new("systemctl").args(enable_args))?;
        println!("✓ Installed systemd user service 'haven-relay' — starts on every login/reboot.");
        println!("  status:  systemctl --user status haven-relay");
        Ok(())
    } else {
        // No systemd → crontab @reboot.
        // No service manager: a tiny restart loop, so the relay comes back after it exits — which
        // is also what lets a signed self-update restart into the new binary (HAVEN_RELAY_SUPERVISED
        // tells the updater something will bring it back; without it the relay only notifies).
        // Replace any older @reboot line first, so an upgrade never leaves TWO relays starting.
        let line = format!(
            "@reboot HAVEN_RELAY_SUPERVISED=1 sh -c 'while :; do {}; sleep 5; done' >/dev/null 2>&1",
            run_cmdline(exe, extra)
        );
        let _ = crontab_remove("haven-relay");
        crontab_add(&line)?;
        println!("✓ Added a crontab @reboot entry — the relay starts on every reboot.");
        Ok(())
    }
}

#[cfg(target_os = "linux")]
fn linux_uninstall() -> Result<()> {
    let _ = Command::new("systemctl").args(["--user", "disable", "--now", "haven-relay"]).status();
    let _ = std::fs::remove_file(home()?.join(".config/systemd/user/haven-relay.service"));
    let _ = crontab_remove("haven-relay");
    println!("✓ Removed the haven-relay auto-start.");
    Ok(())
}

#[cfg(target_os = "linux")]
fn whoami() -> String {
    std::env::var("USER").unwrap_or_else(|_| "".into())
}

#[cfg(target_os = "linux")]
fn crontab_add(line: &str) -> Result<()> {
    let current = Command::new("crontab").arg("-l").output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
    if current.contains(line) {
        return Ok(());
    }
    let mut next = current;
    if !next.is_empty() && !next.ends_with('\n') {
        next.push('\n');
    }
    next.push_str(line);
    next.push('\n');
    pipe_to(Command::new("crontab").arg("-"), &next)
}

#[cfg(target_os = "linux")]
fn crontab_remove(needle: &str) -> Result<()> {
    let current = Command::new("crontab").arg("-l").output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
    let kept: String = current.lines().filter(|l| !l.contains(needle)).map(|l| format!("{l}\n")).collect();
    pipe_to(Command::new("crontab").arg("-"), &kept)
}

#[cfg(target_os = "linux")]
fn pipe_to(cmd: &mut Command, input: &str) -> Result<()> {
    use std::io::Write;
    use std::process::Stdio;
    let mut child = cmd.stdin(Stdio::piped()).spawn()?;
    child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?.write_all(input.as_bytes())?;
    let st = child.wait()?;
    if st.success() { Ok(()) } else { Err(anyhow!("command failed")) }
}

// ── macOS: launchd LaunchAgent ───────────────────────────────────────────────────────────
#[cfg(target_os = "macos")]
fn macos_install(exe: &std::path::Path, extra: &[String], linked: bool) -> Result<()> {
    let agents = home()?.join("Library/LaunchAgents");
    std::fs::create_dir_all(&agents)?;
    let plist_path = agents.join(format!("{LABEL}.plist"));
    let logs = home()?.join("Library/Logs/haven-relay.log");
    // ProgramArguments: exe, "run", then each passthrough flag as its own <string> (no quoting).
    let mut prog = format!("<string>{}</string><string>run</string>", exe.display());
    for a in extra {
        prog.push_str(&format!("<string>{a}</string>"));
    }
    let plist = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\"><dict>\n\
         \t<key>Label</key><string>{LABEL}</string>\n\
         \t<key>ProgramArguments</key><array>{prog}</array>\n\
         \t<key>RunAtLoad</key><true/>\n\t<key>KeepAlive</key><true/>\n\
         \t<key>ProcessType</key><string>Background</string>\n\
         \t<key>StandardOutPath</key><string>{}</string>\n\
         \t<key>StandardErrorPath</key><string>{}</string>\n\
         </dict></plist>\n",
        logs.display(), logs.display()
    );
    std::fs::write(&plist_path, plist)?;
    let _ = Command::new("launchctl").arg("unload").arg(&plist_path).status();
    // Load (and start) now only if linked; otherwise the plist is in place and RunAtLoad picks it
    // up at the next login (after the user attaches a circle).
    if linked {
        run(Command::new("launchctl").arg("load").arg("-w").arg(&plist_path))?;
    }
    println!("✓ Installed launchd agent '{LABEL}' — starts at login and restarts if it exits.");
    println!("  logs:  {}", logs.display());
    Ok(())
}

#[cfg(target_os = "macos")]
fn macos_uninstall() -> Result<()> {
    let plist_path = home()?.join(format!("Library/LaunchAgents/{LABEL}.plist"));
    let _ = Command::new("launchctl").arg("unload").arg(&plist_path).status();
    let _ = std::fs::remove_file(&plist_path);
    println!("✓ Removed the haven-relay launchd agent.");
    Ok(())
}

// ── Windows: Scheduled Task at logon ─────────────────────────────────────────────────────
#[cfg(target_os = "windows")]
fn windows_install(exe: &std::path::Path, extra: &[String], linked: bool) -> Result<()> {
    let tr = run_cmdline(exe, extra);   // "exe" run "--data" "..."
    let _ = Command::new("schtasks").args(["/Delete", "/TN", TASK, "/F"]).status();
    run(Command::new("schtasks").args(["/Create", "/TN", TASK, "/TR", &tr, "/SC", "ONLOGON", "/RL", "LIMITED", "/F"]))?;
    if linked {
        let _ = Command::new("schtasks").args(["/Run", "/TN", TASK]).status();
    }
    println!("✓ Installed Scheduled Task '{TASK}' — haven-relay starts on every logon.");
    println!("  start now:  schtasks /Run /TN {TASK}");
    Ok(())
}

#[cfg(target_os = "windows")]
fn windows_uninstall() -> Result<()> {
    run(Command::new("schtasks").args(["/Delete", "/TN", TASK, "/F"]))?;
    println!("✓ Removed the haven-relay Scheduled Task.");
    Ok(())
}

fn run(cmd: &mut Command) -> Result<()> {
    let st = cmd.status().map_err(|e| anyhow!("failed to launch {:?}: {e}", cmd.get_program()))?;
    if st.success() {
        Ok(())
    } else {
        Err(anyhow!("{:?} exited with {st}", cmd.get_program()))
    }
}

#[cfg(test)]
mod tests {
    //! The pure parts of service installation: which data dir the installed service will use, whether
    //! it starts already linked, and the command line written into the systemd unit / Windows task.
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn the_run_command_line_quotes_every_passthrough_argument() {
        let exe = std::path::Path::new("/opt/haven relay/haven-relay");
        assert_eq!(
            run_cmdline(exe, &s(&["--data", "/srv/my data", "--port", "8674"])),
            "\"/opt/haven relay/haven-relay\" run \"--data\" \"/srv/my data\" \"--port\" \"8674\""
        );
        assert_eq!(run_cmdline(exe, &[]), "\"/opt/haven relay/haven-relay\" run");
    }

    #[test]
    fn a_custom_data_dir_is_honoured_and_hinted() {
        assert_eq!(data_dir(&s(&["--data", "/tmp/x"])), PathBuf::from("/tmp/x"));
        assert_eq!(data_dir(&[]), PathBuf::from(crate::config::default_data_dir()));
        assert_eq!(data_flag_hint(&s(&["--data", "/tmp/x"])), " --data /tmp/x");
        assert_eq!(data_flag_hint(&[]), "");
        // A trailing flag with no value is not a data dir.
        assert_eq!(arg_value(&s(&["--data"]), "--data"), None);
    }

    #[test]
    fn linked_means_a_saved_link_exists_in_that_data_dir() {
        let d = std::env::temp_dir().join(format!("haven-relay-svc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let args = s(&["--data", d.to_str().unwrap()]);
        assert!(!is_linked(&args));
        std::fs::write(d.join("link.json"), "{}").unwrap();
        assert!(is_linked(&args));
        let _ = std::fs::remove_dir_all(&d);
    }
}
