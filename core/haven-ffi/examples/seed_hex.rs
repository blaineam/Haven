use haven_ffi::HavenSocial;
fn main() {
    let seed = std::fs::read("/tmp/ios-seed.bin").unwrap();
    let eng = HavenSocial::new(seed).unwrap();
    println!("account={}", eng.my_node_hex());
}
