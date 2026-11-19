//! The OS secret store, as the client layer uses it.
//!
//! Natively this is the `keyring` crate (Keychain / Credential Manager / Secret Service),
//! re-exported unchanged. A browser has no such store, so on `wasm32` the same `Entry` API keeps
//! secrets under a reserved directory of [`crate::fs`] — `/.secrets/<service>/<account>` — which
//! the page persists like any other file. What protects them there is the page's storage policy
//! (the "my computer" mode wraps that storage under a non-extractable browser key; the "public
//! computer" mode never persists it). A browser device only ever holds its own device key — never
//! an account's master seed — so that is the most this store can leak.

#[cfg(not(target_arch = "wasm32"))]
pub use keyring::*;

#[cfg(target_arch = "wasm32")]
pub use web::*;

#[cfg(any(target_arch = "wasm32", test))]
pub mod web {
    use std::path::PathBuf;

    use crate::fs::mem as store;

    /// The reserved directory secrets live under.
    pub const SECRETS_DIR: &str = "/.secrets";

    #[derive(Debug)]
    pub enum Error {
        /// Nothing is stored under this service + account.
        NoEntry,
        /// The stored bytes are not valid UTF-8.
        BadEncoding,
    }

    impl std::fmt::Display for Error {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            match self {
                Error::NoEntry => write!(f, "no matching entry found in secure storage"),
                Error::BadEncoding => write!(f, "stored secret is not valid text"),
            }
        }
    }

    impl std::error::Error for Error {}

    pub type Result<T> = std::result::Result<T, Error>;

    /// One named secret.
    pub struct Entry {
        path: PathBuf,
    }

    impl Entry {
        pub fn new(service: &str, account: &str) -> Result<Entry> {
            // Both parts are fixed identifiers or hex node ids; keep them from escaping the directory.
            let clean = |s: &str| s.replace(['/', '\\'], "_");
            Ok(Entry { path: PathBuf::from(SECRETS_DIR).join(clean(service)).join(clean(account)) })
        }

        pub fn get_password(&self) -> Result<String> {
            let bytes = store::read(&self.path).map_err(|_| Error::NoEntry)?;
            String::from_utf8(bytes).map_err(|_| Error::BadEncoding)
        }

        pub fn set_password(&self, password: &str) -> Result<()> {
            store::write(&self.path, password.as_bytes()).map_err(|_| Error::NoEntry)
        }

        pub fn delete_credential(&self) -> Result<()> {
            store::remove_file(&self.path).map_err(|_| Error::NoEntry)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn a_secret_round_trips_and_deleting_it_is_final() {
            let e = Entry::new("svc-test", "acct/with/slashes").unwrap();
            assert!(matches!(e.get_password(), Err(Error::NoEntry)));
            e.set_password("s3cret").unwrap();
            assert_eq!(Entry::new("svc-test", "acct/with/slashes").unwrap().get_password().unwrap(), "s3cret");
            assert!(e.path.starts_with(SECRETS_DIR) && e.path.components().count() == 4, "{:?}", e.path);
            e.delete_credential().unwrap();
            assert!(matches!(e.get_password(), Err(Error::NoEntry)));
            assert!(matches!(e.delete_credential(), Err(Error::NoEntry)));
        }
    }
}
