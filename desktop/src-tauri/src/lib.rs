//! Haven desktop — Tauri 2 GUI client plus a headless circle-relay mode, both built on the
//! shared Rust core (`haven_ffi`). The GUI is the WebView2 frontend in `../ui`; `--headless`
//! runs only the in-process relay/mailbox (the "invisible relay", like the Mac app).

mod callwire;
mod commands;
mod engine;
mod localmedia;
mod relayhealth;
mod roster;
mod scheduled;
mod secret;
mod selfsync;
mod store;
mod wire;

use std::sync::Arc;

use anyhow::{anyhow, Result};
use haven_ffi::Account;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager};

use crate::engine::Engine;
use crate::store::Paths;

/// `haven://…` URLs the OS has handed us that the frontend hasn't routed yet.
///
/// A queue rather than an event payload because a deep link is often what LAUNCHED Haven: it arrives
/// before the webview exists, and an event emitted then is dropped on the floor. The frontend drains
/// this at boot AND on the `haven:deep-link` ping, so either order works.
#[derive(Default)]
pub struct DeepLinks(pub std::sync::Mutex<Vec<String>>);

/// Load the master seed from the secure store, or mint + persist a new identity.
fn ensure_seed() -> Result<[u8; 32]> {
    if let Some(s) = store::load_seed()? {
        return Ok(s);
    }
    let acct: Arc<Account> = Account::generate();
    let seed: [u8; 32] = acct
        .secret_seed()
        .try_into()
        .map_err(|_| anyhow!("generated seed is not 32 bytes"))?;
    store::save_seed(&seed)?;
    Ok(seed)
}

/// Resolve the active identity's seed + data dir, migrating a legacy single-identity install
/// into the roster on first run (the legacy identity keeps the existing flat data dir).
fn ensure_active_identity() -> Result<([u8; 32], Paths)> {
    let base = Paths::resolve()?;
    let mut ids = store::Identities::load(&base);

    if ids.is_empty() {
        // First run (or pre-roster install): adopt the legacy seed, or mint a fresh identity.
        let seed = match store::load_seed()? {
            Some(s) => s,
            None => {
                let acct: Arc<Account> = Account::generate();
                let s: [u8; 32] = acct
                    .secret_seed()
                    .try_into()
                    .map_err(|_| anyhow!("generated seed is not 32 bytes"))?;
                store::save_seed(&s)?;
                s
            }
        };
        let hex = Account::from_seed(seed.to_vec())
            .map_err(|e| anyhow!("derive node id: {e}"))?
            .node_id_hex();
        store::save_identity_seed(&hex, &seed)?;
        ids.add(&hex, "Identity 1"); // first identity → legacy root, active
        ids.save(&base)?;
        return Ok((seed, Paths::resolve_for("")?));
    }

    let entry = ids
        .active_entry()
        .cloned()
        .ok_or_else(|| anyhow!("roster has no active identity"))?;
    let seed = match store::load_identity_seed(&entry.node_hex)? {
        Some(s) => s,
        None => store::load_seed()?.ok_or_else(|| anyhow!("active identity seed missing"))?,
    };
    // Keep the legacy `master-seed` mirrored to the active identity so the headless relay follows.
    let _ = store::save_seed(&seed);
    Ok((seed, Paths::resolve_for(&entry.dir)?))
}

/// GUI variant of `ensure_active_identity`: returns `None` on a truly fresh install (empty roster
/// + no legacy seed) instead of auto-minting. The GUI then shows a welcome screen and the user
/// explicitly creates or links an identity (which persists the seed and relaunches into the
/// normal startup path). A legacy single-seed install is still migrated and counts as existing.
fn active_identity_if_exists() -> Result<Option<([u8; 32], Paths)>> {
    let base = Paths::resolve()?;
    let ids = store::Identities::load(&base);

    if ids.is_empty() {
        if let Some(seed) = store::load_seed()? {
            // Pre-roster install: migrate the legacy seed into the roster (keeps its flat dir).
            let hex = Account::from_seed(seed.to_vec())
                .map_err(|e| anyhow!("derive node id: {e}"))?
                .node_id_hex();
            store::save_identity_seed(&hex, &seed)?;
            let mut ids = ids;
            ids.add(&hex, "Identity 1");
            ids.save(&base)?;
            return Ok(Some((seed, Paths::resolve_for("")?)));
        }
        return Ok(None); // fresh — no auto-create; the frontend onboards.
    }

    let entry = ids
        .active_entry()
        .cloned()
        .ok_or_else(|| anyhow!("roster has no active identity"))?;
    let seed = match store::load_identity_seed(&entry.node_hex)? {
        Some(s) => s,
        None => store::load_seed()?.ok_or_else(|| anyhow!("active identity seed missing"))?,
    };
    let _ = store::save_seed(&seed);
    Ok(Some((seed, Paths::resolve_for(&entry.dir)?)))
}

/// Run the full GUI app.
pub fn run() {
    // Fresh install → no engine; the frontend shows the welcome screen and `onboard_*` relaunches.
    let existing = active_identity_if_exists().expect("resolve identity");

    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        // Managed before the identity check so `take_deep_links` answers even on the welcome screen.
        .manage(DeepLinks::default());

    let builder = match existing {
        Some((seed, paths)) => {
            let engine = Engine::new(paths, seed).expect("build engine");
            let setup_engine = engine.clone();
            builder.manage(engine).setup(move |app| {
                let handle = app.handle().clone();
                setup_engine.set_app(handle.clone());
                // haven:// deep links (a tapped invite, or a shared post) — surface the window and hand
                // the URL to the frontend (parity with the iOS URL scheme / Android intent filter).
                // Windows/Linux register the scheme at install time via the plugin; register_all covers
                // dev builds.
                //
                // The URL is QUEUED for the frontend rather than routed here: `haven://p/<c>/<p>` (a post)
                // and `haven://invite#<id>.<verify>` are different destinations, and one parser has to
                // decide which — feeding them all to `connect_by_link` is how a post link gets swallowed
                // by the invite flow. That parser lives in app.js (`DeepLink`), next to the UI it drives.
                //
                // NOTE: the OS only ever gives us `haven://` links. Desktop CANNOT claim
                // https://wemiller.com/apps/haven/… — the deep-link plugin matches on scheme only on
                // desktop (its config takes `schemes`, and Universal Links / App Links are mobile-only),
                // so the shareable https post link reaches us the same way an https invite already does:
                // the landing page resolves the fragment client-side and bounces to `haven://p/…`
                // (web/index.html), or the user pastes it into Connect. app.js parses both forms.
                {
                    use tauri_plugin_deep_link::DeepLinkExt;
                    #[cfg(any(target_os = "linux", windows))]
                    let _ = app.deep_link().register_all();
                    let link_handle = handle.clone();
                    app.deep_link().on_open_url(move |event| {
                        if let Some(q) = link_handle.try_state::<DeepLinks>() {
                            let mut pending = q.0.lock().unwrap();
                            pending.extend(event.urls().iter().map(|u| u.to_string()));
                        }
                        let _ = link_handle.emit("haven:deep-link", ());
                        if let Some(w) = link_handle.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    });
                }
                let e = setup_engine.clone();
                tauri::async_runtime::spawn(async move {
                    e.start().await;
                    // If the user opted in, host the relay automatically — combined with
                    // launch-on-login this makes the desktop app a reboot-surviving relay.
                    if e.host_on_launch() {
                        let _ = e.start_hosting().await;
                    }
                });

                // System tray: show the window, toggle the relay, or quit. The relay keeps running
                // when the window is closed, so the tray is the "invisible background relay" surface.
                let show = MenuItem::with_id(app, "show", "Open Haven", true, None::<&str>)?;
                let relay = MenuItem::with_id(app, "relay", "Host relay", true, None::<&str>)?;
                let quit = MenuItem::with_id(app, "quit", "Quit Haven", true, None::<&str>)?;
                let menu = Menu::with_items(app, &[&show, &relay, &quit])?;
                let tray_engine = setup_engine.clone();
                TrayIconBuilder::with_id("haven-tray")
                    .icon(app.default_window_icon().unwrap().clone())
                    .tooltip("Haven")
                    .menu(&menu)
                    .show_menu_on_left_click(true)
                    .on_menu_event(move |app, event| match event.id().as_ref() {
                        "show" => {
                            if let Some(w) = app.get_webview_window("main") {
                                let _ = w.show();
                                let _ = w.set_focus();
                            }
                        }
                        "relay" => {
                            let e = tray_engine.clone();
                            tauri::async_runtime::spawn(async move {
                                let _ = e.start_hosting().await;
                            });
                        }
                        "quit" => app.exit(0),
                        _ => {}
                    })
                    .build(app)?;
                Ok(())
            })
        }
        // No identity yet: bring up the window with no engine. The frontend's `needs_onboarding`
        // check renders the welcome screen; `onboard_create`/`onboard_link` relaunch into the app.
        None => builder.setup(|_app| Ok(())),
    };

    builder
        .invoke_handler(tauri::generate_handler![
            commands::needs_onboarding,
            commands::onboard_create,
            commands::onboard_link,
            commands::bootstrap,
            commands::self_test,
            commands::get_profile,
            commands::set_profile,
            commands::circles,
            commands::create_circle,
            commands::rename_circle,
            commands::leave_circle,
            commands::add_to_circle,
            commands::remove_from_circle,
            commands::feed,
            commands::post,
            commands::post_story,
            commands::comment,
            commands::react,
            commands::unreact,
            commands::edit_post,
            commands::unsend_post,
            commands::report,
            commands::reports,
            commands::dm_threads,
            commands::mark_dm_read,
            commands::delete_conversation,
            commands::start_dm,
            commands::start_group_dm,
            commands::sync_status,
            commands::video_sound_on,
            commands::set_video_sound,
            commands::device_roster,
            commands::enable_device_roster,
            commands::request_device_enrollment,
            commands::revoke_device,
            commands::step_down_as_primary,
            commands::messages,
            commands::send_dm,
            commands::connect_by_link,
            commands::take_deep_links,
            commands::pending,
            commands::approve,
            commands::dismiss,
            commands::contacts,
            commands::blocked,
            commands::block,
            commands::unblock,
            commands::relay_status,
            commands::start_hosting,
            commands::stop_hosting,
            commands::adopt_relay,
            commands::relays,
            commands::forget_relay,
            commands::reactivate_relay,
            commands::rename_relay,
            commands::set_default_relay,
            commands::erase_relay,
            commands::set_circle_relay,
            commands::circle_relays,
            commands::add_s3_relay,
            commands::autostart_status,
            commands::set_autostart,
            commands::add_media,
            commands::add_media_path,
            commands::add_audio,
            commands::media_data_url,
            commands::schedule_message,
            commands::scheduled,
            commands::cancel_scheduled,
            commands::call_group_invite,
            commands::call_accept,
            commands::call_hangup,
            commands::call_signal,
            commands::my_node_hex,
            commands::identities,
            commands::add_identity,
            commands::import_identity,
            commands::rename_identity,
            commands::remove_identity,
            commands::switch_identity,
            commands::s3_status,
            commands::s3_configure,
            commands::s3_clear,
            commands::set_foreground,
            commands::reset,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Haven");
}

/// Run with no window. Serves the circle relay/mailbox (E2E-sealed blobs it can never read) AND
/// runs the active identity's engine so **scheduled messages dispatch and the mailbox syncs even
/// with the GUI closed** — leave this running on an always-on machine and "send later" works
/// without the app open. The messaging keys stay on this machine (the relay still never sees
/// plaintext); the relay node id is derived from a distinct relay-specific seed.
pub fn run_headless() {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    rt.block_on(async {
        let (seed, paths) = ensure_active_identity().expect("load or create identity");

        let dir = paths.relay_dir();
        std::fs::create_dir_all(&dir).ok();

        // Build + start the engine for the active identity: this brings up the messaging node,
        // the 15s mailbox poll, and the scheduled-message dispatcher (which also flushes anything
        // overdue on launch). No AppHandle → notifications/UI events are simply no-ops.
        let engine = Engine::new(paths.clone(), seed).expect("build engine");
        engine.start().await;
        // Attach the relay to the engine's messaging node (ONE iroh node, two ALPNs) — a separate relay
        // node in the same process is what made iroh churn paths unboundedly (the tens-of-GB leak).
        let node_hex = engine.start_hosting().await.expect("attach relay host");

        let prefs = store::Prefs::load(&paths);
        let members: Vec<String> = prefs.contacts.iter().map(|c| c.id_hex.clone()).collect();
        let link = haven_ffi::make_relay_link(node_hex.clone(), members);
        let pending = engine.list_scheduled().len();

        println!("Haven relay + scheduler running.");
        println!("  relay node id : {node_hex}");
        println!("  relay link    : {link}");
        println!("  storage       : {}", dir.display());
        println!("  scheduled     : {pending} message(s) queued — they'll send while this runs");
        println!("Share the relay link with your circle, then leave this running. Ctrl-C to stop.");

        let _ = tokio::signal::ctrl_c().await;
        println!("\nStopping.");
        drop(engine); // stops the relay (attached to the engine's node) + the messaging node
    });
}
