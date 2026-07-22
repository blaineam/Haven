fn main() {
    let seed = std::fs::read("/tmp/tauri-device-seed.bin").unwrap();
    let a = haven_ffi::Account::from_seed(seed).unwrap();
    println!("device={}", a.node_id_hex());
}
