mod commands;
mod events;
mod history;
mod llm;
// A complete hand-mirror of llm-ipc-v1; some constructors are exercised only by
// its round-trip tests (and future backends), so allow unused here.
#[allow(dead_code)]
mod llm_protocol;
mod protocol;
// Proprietary cloud tier (gitignored). The `mod` line is only compiled with the
// `saas` feature, so the OSS build never references the absent `src/saas/` dir.
#[cfg(feature = "saas")]
mod saas;
mod session;
mod settings;
mod sidecar;

use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,minutiae_lib=debug".into()),
        )
        .with_writer(std::io::stderr)
        .init();

    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init());
    // Deep-link plugin handles the prod OAuth redirect (minutiae://oauth/callback).
    #[cfg(feature = "saas")]
    let builder = builder.plugin(tauri_plugin_deep_link::init());

    builder
        .setup(|app| {
            // Settings live next to sessions under the app data dir.
            let settings_path = app
                .path()
                .data_dir()?
                .join("Minutiae")
                .join("settings.json");
            app.manage(settings::SettingsState::load(settings_path));

            let manager = sidecar::SidecarManager::new(app.handle().clone());
            // Self-heal sessions a previous run left unfinalized (crash /
            // force-quit): backfill their session.json so they reappear in
            // Recents instead of being silently stranded on disk.
            if let Ok(root) = manager.sessions_root() {
                let n = history::recover_orphaned_sessions(&root);
                if n > 0 {
                    tracing::info!(recovered = n, "recovered unfinalized sessions at startup");
                }
            }
            manager.start();
            app.manage(manager);

            // LLM enhancement sidecar is spawned lazily on the first enhance.
            app.manage(llm::LlmManager::new(app.handle().clone()));

            // SaaS tier: account/auth + cloud sync managers (gitignored module).
            #[cfg(feature = "saas")]
            {
                app.manage(saas::AuthManager::new(app.handle().clone()));
                app.manage(saas::SyncManager::new(app.handle().clone()));

                // Background sync: replicate session text artifacts periodically
                // while signed in. The first tick fires immediately (syncs on
                // launch if already signed in); the emitted `saas:sync_status`
                // keeps the UI indicator fresh. `sync_if_idle` no-ops when signed
                // out and coalesces with any manual sync.
                let sync_handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    let mut tick =
                        tokio::time::interval(std::time::Duration::from_secs(120));
                    loop {
                        tick.tick().await;
                        if let Some(sync) =
                            sync_handle.try_state::<saas::SyncManager>()
                        {
                            sync.sync_if_idle().await;
                        }
                    }
                });

                // Route the OAuth deep link (minutiae://oauth/callback?code=…) to
                // the AuthManager waiting on the in-flight login.
                use tauri_plugin_deep_link::DeepLinkExt;
                let handle = app.handle().clone();
                app.deep_link().on_open_url(move |event| {
                    for url in event.urls() {
                        if let Some(auth) = handle.try_state::<saas::AuthManager>() {
                            auth.handle_deep_link(url.as_str());
                        }
                    }
                });
                // No-op on macOS (scheme comes from the bundle Info.plist); needed
                // for runtime registration on Linux/Windows dev.
                let _ = app.deep_link().register_all();
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::list_devices,
            commands::start_session,
            commands::stop_session,
            commands::prepare_models,
            commands::get_state,
            commands::get_settings,
            commands::set_vault_dir,
            commands::set_thinking_mode,
            commands::set_asr_model,
            commands::save_scratchpad,
            commands::load_scratchpad,
            commands::list_sessions,
            commands::open_session,
            commands::delete_session,
            commands::reveal_transcript_note,
            commands::enhance_session,
            commands::cancel_enhance,
            commands::get_llm_status,
            commands::prepare_llm,
            #[cfg(feature = "saas")]
            saas::auth::saas_login,
            #[cfg(feature = "saas")]
            saas::auth::saas_logout,
            #[cfg(feature = "saas")]
            saas::auth::saas_account_status,
            #[cfg(feature = "saas")]
            saas::sync::saas_sync_now,
            #[cfg(feature = "saas")]
            saas::sync::saas_sync_status,
            #[cfg(feature = "saas")]
            saas::config::saas_get_cloud_enrich,
            #[cfg(feature = "saas")]
            saas::config::saas_set_cloud_enrich,
            #[cfg(feature = "saas")]
            saas::config::saas_get_dismissed_sign_in,
            #[cfg(feature = "saas")]
            saas::config::saas_dismiss_sign_in,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
