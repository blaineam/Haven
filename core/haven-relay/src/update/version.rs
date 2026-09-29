//! Release versions, update channels and "which release should this relay move to?".
//!
//! Haven tags are `vX.Y.Z` (stable), `vX.Y.Z-rc.N` (release candidate, published as a GitHub
//! PRE-release) and `relay-vX.Y.Z` (relay-only hotfix). Ordering is semver restricted to the one
//! pre-release form Haven allows: `X.Y.Z-rc.N < X.Y.Z`, and `rc.2 < rc.10` (numeric).

use std::cmp::Ordering;
use std::fmt;

/// A parsed relay version. `rc == None` is a stable release.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Version {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
    pub rc: Option<u64>,
}

impl Version {
    /// Parse `1.2.3`, `1.2.3-rc.4`, optionally prefixed `v` / `relay-v` (a tag name).
    pub fn parse(s: &str) -> Option<Self> {
        let s = s.trim();
        let s = s.strip_prefix("relay-v").or_else(|| s.strip_prefix('v')).unwrap_or(s);
        let (core, rc) = match s.split_once('-') {
            Some((core, pre)) => {
                let n = pre.strip_prefix("rc.")?;
                if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                (core, Some(n.parse().ok()?))
            }
            None => (s, None),
        };
        let mut it = core.split('.');
        let mut num = || -> Option<u64> {
            let p = it.next()?;
            if p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            p.parse().ok()
        };
        let (major, minor, patch) = (num()?, num()?, num()?);
        if it.next().is_some() {
            return None;
        }
        Some(Version { major, minor, patch, rc })
    }

    pub fn is_prerelease(&self) -> bool {
        self.rc.is_some()
    }
}

impl Ord for Version {
    fn cmp(&self, o: &Self) -> Ordering {
        (self.major, self.minor, self.patch)
            .cmp(&(o.major, o.minor, o.patch))
            .then_with(|| match (self.rc, o.rc) {
                (None, None) => Ordering::Equal,
                (None, Some(_)) => Ordering::Greater, // 1.2.0 > 1.2.0-rc.N
                (Some(_), None) => Ordering::Less,
                (Some(a), Some(b)) => a.cmp(&b),
            })
    }
}
impl PartialOrd for Version {
    fn partial_cmp(&self, o: &Self) -> Option<Ordering> {
        Some(self.cmp(o))
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)?;
        if let Some(n) = self.rc {
            write!(f, "-rc.{n}")?;
        }
        Ok(())
    }
}

/// Which releases the updater follows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Channel {
    /// Never check, never install.
    Off,
    /// Newest non-prerelease.
    Stable,
    /// Newest release INCLUDING prereleases (release candidates).
    Rc,
}

impl Channel {
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "off" | "none" | "no" | "false" | "0" | "disabled" => Some(Channel::Off),
            "stable" | "on" | "yes" | "true" | "1" | "latest" => Some(Channel::Stable),
            "rc" | "prerelease" | "beta" | "candidate" => Some(Channel::Rc),
            _ => None,
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            Channel::Off => "off",
            Channel::Stable => "stable",
            Channel::Rc => "rc",
        }
    }
}

/// One asset of a release, as the GitHub API lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Asset {
    pub name: String,
    pub url: String,
    pub size: u64,
}

/// One release, as the GitHub API lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Release {
    pub tag: String,
    pub prerelease: bool,
    pub draft: bool,
    pub assets: Vec<Asset>,
}

/// The release the updater decided to install.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub version: Version,
    pub tag: String,
    pub asset: Asset,
    pub sig: Asset,
}

/// Pick the release to move to, or `None` to stay put.
///
/// * `Stable` considers only non-prerelease, non-draft releases whose tag is a plain `X.Y.Z`.
/// * `Rc` considers every non-draft release (stable AND candidates).
/// * Never a downgrade: the pick must be STRICTLY newer than `current` — so an rc-channel relay
///   on a newer stable never "updates" to an older candidate, and a stable-channel relay that was
///   hand-installed on a candidate simply waits for the stable release that supersedes it.
/// * Versions in `bad` (failed health after install) are never picked again.
/// * A release must carry BOTH the asset for this target and its `.sig`; one that doesn't is
///   skipped (not an error) — the newest release that does is chosen instead.
pub fn select_update(
    current: &Version,
    channel: Channel,
    releases: &[Release],
    bad: &[Version],
    asset_name: &str,
) -> Option<Candidate> {
    if channel == Channel::Off {
        return None;
    }
    let sig_name = format!("{asset_name}.sig");
    releases
        .iter()
        .filter(|r| !r.draft)
        .filter_map(|r| {
            let v = Version::parse(&r.tag)?;
            // A GitHub "prerelease" flag with a clean version (or an rc tag not flagged prerelease)
            // counts as a prerelease either way — belt and braces for the stable channel.
            let pre = r.prerelease || v.is_prerelease();
            if channel == Channel::Stable && pre {
                return None;
            }
            if &v <= current || bad.contains(&v) {
                return None;
            }
            let asset = r.assets.iter().find(|a| a.name == asset_name)?.clone();
            let sig = r.assets.iter().find(|a| a.name == sig_name)?.clone();
            Some(Candidate { version: v, tag: r.tag.clone(), asset, sig })
        })
        .max_by(|a, b| a.version.cmp(&b.version))
}

/// The release asset name for a Rust target triple (`haven-relay-<target>[.exe]`), mapping glibc
/// Linux triples to the static musl build the releases actually ship (it runs on any Linux).
/// `None` when no release asset exists for this platform (auto-update is then notify-only).
pub fn asset_name_for_target(triple: &str) -> Option<String> {
    let mapped = match triple {
        "x86_64-unknown-linux-gnu" | "x86_64-unknown-linux-musl" => "x86_64-unknown-linux-musl",
        "aarch64-unknown-linux-gnu" | "aarch64-unknown-linux-musl" => "aarch64-unknown-linux-musl",
        "armv7-unknown-linux-gnueabihf" | "armv7-unknown-linux-musleabihf" => "armv7-unknown-linux-musleabihf",
        "arm-unknown-linux-gnueabihf" | "arm-unknown-linux-musleabihf" => "arm-unknown-linux-musleabihf",
        "aarch64-apple-darwin" | "x86_64-apple-darwin" => triple,
        "x86_64-pc-windows-msvc" | "aarch64-pc-windows-msvc" => {
            return Some(format!("haven-relay-{triple}.exe"));
        }
        _ => return None,
    };
    Some(format!("haven-relay-{mapped}"))
}

/// Parse the GitHub "list releases" JSON (`GET /repos/{o}/{r}/releases`). Unknown/malformed
/// entries are skipped rather than failing the whole check.
pub fn parse_releases(json: &[u8]) -> Result<Vec<Release>, String> {
    let v: serde_json::Value = serde_json::from_slice(json).map_err(|e| format!("release list is not JSON: {e}"))?;
    let arr = v.as_array().ok_or("release list is not an array")?;
    Ok(arr
        .iter()
        .filter_map(|r| {
            let tag = r.get("tag_name")?.as_str()?.to_string();
            let assets = r
                .get("assets")
                .and_then(|a| a.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| {
                            Some(Asset {
                                name: x.get("name")?.as_str()?.to_string(),
                                url: x.get("browser_download_url")?.as_str()?.to_string(),
                                size: x.get("size").and_then(|s| s.as_u64()).unwrap_or(0),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(Release {
                tag,
                prerelease: r.get("prerelease").and_then(|b| b.as_bool()).unwrap_or(false),
                draft: r.get("draft").and_then(|b| b.as_bool()).unwrap_or(false),
                assets,
            })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &str) -> Version {
        Version::parse(s).unwrap()
    }

    #[test]
    fn parses_tags_and_rejects_junk() {
        assert_eq!(v("1.2.3"), Version { major: 1, minor: 2, patch: 3, rc: None });
        assert_eq!(v("v1.2.3-rc.4"), Version { major: 1, minor: 2, patch: 3, rc: Some(4) });
        assert_eq!(v("relay-v1.1.5"), v("1.1.5"));
        assert_eq!(v("1.2.3-rc.4").to_string(), "1.2.3-rc.4");
        for bad in ["", "1.2", "1.2.3.4", "1.2.3-beta.1", "1.2.3-rc", "1.2.3-rc.x", "x.2.3", "v", "1..3", "1.2.3-rc.-1", "desktop-v1.2.3"] {
            assert!(Version::parse(bad).is_none(), "{bad} must not parse");
        }
    }

    #[test]
    fn semver_ordering_with_rc() {
        assert!(v("1.2.0-rc.1") < v("1.2.0"));
        assert!(v("1.2.0-rc.2") < v("1.2.0-rc.10"), "rc numbers compare numerically");
        assert!(v("1.1.9") < v("1.2.0-rc.1"));
        assert!(v("1.2.0") < v("1.2.1-rc.1"));
        assert!(v("1.10.0") > v("1.9.9"));
        assert_eq!(v("v1.2.0").cmp(&v("relay-v1.2.0")), Ordering::Equal);
    }

    fn rel(tag: &str, pre: bool, asset: &str) -> Release {
        Release {
            tag: tag.into(),
            prerelease: pre,
            draft: false,
            assets: vec![
                Asset { name: asset.into(), url: format!("https://x/{tag}/{asset}"), size: 1 },
                Asset { name: format!("{asset}.sig"), url: format!("https://x/{tag}/{asset}.sig"), size: 1 },
                Asset { name: "haven-relay-other".into(), url: "https://x/o".into(), size: 1 },
            ],
        }
    }

    const A: &str = "haven-relay-x86_64-unknown-linux-musl";

    #[test]
    fn stable_channel_picks_newest_stable_only() {
        let rs = vec![rel("v1.2.0", false, A), rel("v1.3.0-rc.1", true, A), rel("v1.1.0", false, A), rel("relay-v1.2.1", false, A)];
        let c = select_update(&v("1.1.0"), Channel::Stable, &rs, &[], A).unwrap();
        assert_eq!(c.version, v("1.2.1"), "relay-v hotfix tags count");
        assert_eq!(c.sig.name, format!("{A}.sig"));
        assert!(select_update(&v("1.2.1"), Channel::Stable, &rs, &[], A).is_none(), "already newest");
        // An rc tag mis-flagged as a full release is still a prerelease.
        let rs2 = vec![rel("v1.3.0-rc.1", false, A)];
        assert!(select_update(&v("1.2.0"), Channel::Stable, &rs2, &[], A).is_none());
        assert!(select_update(&v("1.0.0"), Channel::Off, &rs, &[], A).is_none());
    }

    #[test]
    fn rc_channel_includes_candidates_but_never_downgrades() {
        let rs = vec![rel("v1.2.0", false, A), rel("v1.3.0-rc.2", true, A), rel("v1.3.0-rc.10", true, A)];
        assert_eq!(select_update(&v("1.2.0"), Channel::Rc, &rs, &[], A).unwrap().version, v("1.3.0-rc.10"));
        // A newer stable never moves to an older rc.
        let rs = vec![rel("v1.3.0", false, A), rel("v1.3.0-rc.9", true, A), rel("v1.2.5-rc.1", true, A)];
        assert!(select_update(&v("1.3.0"), Channel::Rc, &rs, &[], A).is_none());
        // Stable-channel relay hand-installed on an rc waits for the stable that supersedes it.
        let rs = vec![rel("v1.2.9", false, A)];
        assert!(select_update(&v("1.3.0-rc.1"), Channel::Stable, &rs, &[], A).is_none());
        let rs = vec![rel("v1.3.0", false, A)];
        assert_eq!(select_update(&v("1.3.0-rc.1"), Channel::Stable, &rs, &[], A).unwrap().version, v("1.3.0"));
    }

    #[test]
    fn bad_versions_drafts_and_missing_assets_are_skipped() {
        let mut draft = rel("v1.5.0", false, A);
        draft.draft = true;
        let mut unsigned = rel("v1.4.0", false, A);
        unsigned.assets.retain(|a| !a.name.ends_with(".sig"));
        let rs = vec![draft, unsigned, rel("v1.3.0", false, A), rel("v1.2.0", false, A), rel("v1.3.1", false, "haven-relay-aarch64-apple-darwin")];
        // 1.5.0 draft, 1.4.0 unsigned, 1.3.1 lacks our asset → 1.3.0; unless 1.3.0 is bad → 1.2.0.
        assert_eq!(select_update(&v("1.1.0"), Channel::Stable, &rs, &[], A).unwrap().version, v("1.3.0"));
        assert_eq!(select_update(&v("1.1.0"), Channel::Stable, &rs, &[v("1.3.0")], A).unwrap().version, v("1.2.0"));
        assert!(select_update(&v("1.2.0"), Channel::Stable, &rs, &[v("1.3.0")], A).is_none());
    }

    #[test]
    fn asset_names_per_target() {
        assert_eq!(asset_name_for_target("x86_64-unknown-linux-musl").unwrap(), A);
        assert_eq!(asset_name_for_target("x86_64-unknown-linux-gnu").unwrap(), A, "glibc builds follow the static musl asset");
        assert_eq!(asset_name_for_target("aarch64-unknown-linux-gnu").unwrap(), "haven-relay-aarch64-unknown-linux-musl");
        assert_eq!(asset_name_for_target("armv7-unknown-linux-musleabihf").unwrap(), "haven-relay-armv7-unknown-linux-musleabihf");
        assert_eq!(asset_name_for_target("arm-unknown-linux-gnueabihf").unwrap(), "haven-relay-arm-unknown-linux-musleabihf");
        assert_eq!(asset_name_for_target("aarch64-apple-darwin").unwrap(), "haven-relay-aarch64-apple-darwin");
        assert_eq!(asset_name_for_target("x86_64-pc-windows-msvc").unwrap(), "haven-relay-x86_64-pc-windows-msvc.exe");
        assert!(asset_name_for_target("riscv64gc-unknown-linux-gnu").is_none());
    }

    #[test]
    fn parses_github_release_json() {
        let json = br#"[
          {"tag_name":"v1.2.0-rc.1","prerelease":true,"draft":false,"assets":[
             {"name":"haven-relay-x86_64-unknown-linux-musl","browser_download_url":"https://github.com/o/r/releases/download/v1.2.0-rc.1/haven-relay-x86_64-unknown-linux-musl","size":123}]},
          {"tag_name":"v1.1.0","prerelease":false,"draft":false,"assets":[]},
          {"no_tag":true}
        ]"#;
        let rs = parse_releases(json).unwrap();
        assert_eq!(rs.len(), 2);
        assert!(rs[0].prerelease);
        assert_eq!(rs[0].assets[0].size, 123);
        assert!(parse_releases(b"{}").is_err());
    }
}
