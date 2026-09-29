//! Bake the build's target triple into the binary (the self-updater downloads the release asset
//! for exactly this target), and rebuild when CI stamps a release version.
fn main() {
    let target = std::env::var("TARGET").unwrap_or_default();
    println!("cargo:rustc-env=HAVEN_RELAY_TARGET={target}");
    println!("cargo:rerun-if-env-changed=HAVEN_RELAY_BUILD_VERSION");
    println!("cargo:rerun-if-changed=build.rs");
}
