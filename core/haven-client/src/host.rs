//! What the client layer asks of the application around it: deliver an event to the user
//! interface, and raise an OS notification. The desktop app implements this over Tauri; the
//! browser build over a page callback and the Notifications API.

use std::sync::Arc;

/// The application hosting an [`Engine`](crate::engine::Engine).
pub trait Host: Send + Sync {
    /// Deliver a named event with a JSON payload to the user interface.
    fn emit(&self, event: &str, payload: serde_json::Value) -> Result<(), String>;
    /// Raise a native notification (toast / Notification Center). Best effort.
    fn notify(&self, title: &str, body: &str);
}

/// A cheap, cloneable handle to the host — the role Tauri's `AppHandle` played for the engine when
/// it lived in the desktop crate, hence the name.
#[derive(Clone)]
pub struct AppHandle(Arc<dyn Host>);

impl AppHandle {
    pub fn new(host: Arc<dyn Host>) -> Self {
        Self(host)
    }

    /// Emit `event` with any serializable payload (`()` becomes JSON `null`).
    pub fn emit<S: serde::Serialize>(&self, event: &str, payload: S) -> Result<(), String> {
        let value = serde_json::to_value(payload).map_err(|e| e.to_string())?;
        self.0.emit(event, value)
    }

    pub fn notify(&self, title: &str, body: &str) {
        self.0.notify(title, body);
    }
}
