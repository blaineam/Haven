//! Task spawning for the client layer, so nothing in it names a host's runtime.
//!
//! The desktop app hands over its Tauri runtime's handle once at startup ([`set_runtime`]); from
//! then on [`spawn`] works from any thread — including the transport's inbound-callback threads,
//! which are not inside a runtime and where a bare `tokio::spawn` would panic.

use std::future::Future;
use std::sync::OnceLock;

use tokio::runtime::{Handle, Runtime};
pub use tokio::task::JoinHandle;

static HOST: OnceLock<Handle> = OnceLock::new();
static OWN: OnceLock<Runtime> = OnceLock::new();

/// Adopt the host application's runtime. First call wins; later calls are ignored.
pub fn set_runtime(handle: Handle) {
    let _ = HOST.set(handle);
}

/// The runtime tasks go to: the host's if one was set, else a multi-threaded runtime of this
/// crate's own, started on first use (unit tests, tools).
///
/// Deliberately NOT "whatever runtime this thread is in": background work must keep running while
/// its caller blocks, and a caller on a current-thread runtime (`#[tokio::test]`) would otherwise
/// have its tasks parked until it next awaits. One process-wide runtime, as Tauri's was.
fn handle() -> Handle {
    if let Some(h) = HOST.get() {
        return h.clone();
    }
    OWN.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("client runtime")
    })
    .handle()
    .clone()
}

/// Run a future to completion in the background.
pub fn spawn<F>(future: F) -> JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    handle().spawn(future)
}

/// Run blocking work (file IO, heavy CPU) off the async workers.
pub fn spawn_blocking<F, R>(f: F) -> JoinHandle<R>
where
    F: FnOnce() -> R + Send + 'static,
    R: Send + 'static,
{
    handle().spawn_blocking(f)
}

/// Drive a future to completion from synchronous code that is NOT on a runtime worker.
pub fn block_on<F: Future>(future: F) -> F::Output {
    handle().block_on(future)
}
