#![windows_subsystem = "windows"]

mod backend;
mod ipc;
mod updater;
mod win32;

use std::borrow::Cow;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::{Duration, Instant};

use muda::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tao::dpi::{LogicalSize, PhysicalPosition};
use tao::event::{Event, StartCause, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy, EventLoopWindowTarget};
use tao::platform::windows::WindowBuilderExtWindows;
use tao::window::{Icon as TaoIcon, Window, WindowBuilder};
use tray_icon::menu::MenuId;
use tray_icon::{Icon as TrayIcon, MouseButton, MouseButtonState, TrayIcon as SysTrayIcon, TrayIconBuilder, TrayIconEvent};
use wry::http::{header::CONTENT_TYPE, Request, Response};
use wry::{WebContext, WebView, WebViewBuilder};

use backend::BackendSupervisor;
use ipc::{compute_ipc_endpoint, rpc_call};
use updater::UpdateState;

const EMBEDDED_ICO: &[u8] = include_bytes!("../../assets/icons/app.ico");

const INIT_BRIDGE_JS: &str = r#"
(() => {
  if (window.gravitybox) return;
  const pending = new Map();
  const listeners = new Map();
  let nextId = 1;
  window.__gbResolve = (reqId, ok, payload) => {
    const entry = pending.get(reqId);
    if (!entry) return;
    pending.delete(reqId);
    if (ok) entry.resolve(payload);
    else entry.reject(new Error(typeof payload === 'string' ? payload : (payload?.error || 'IPC error')));
  };
  window.__gbEmit = (channel, data) => {
    const arr = listeners.get(channel);
    if (!arr) return;
    for (const fn of arr) { try { fn(data); } catch {} }
  };
  function invoke(cmd, payload) {
    return new Promise((resolve, reject) => {
      const reqId = nextId++;
      pending.set(reqId, { resolve, reject });
      try {
        window.ipc.postMessage(JSON.stringify({ reqId, cmd, payload: payload ?? {} }));
      } catch (err) {
        pending.delete(reqId);
        reject(err);
      }
    });
  }
  function on(channel, cb) {
    if (typeof cb !== 'function') return () => {};
    if (!listeners.has(channel)) listeners.set(channel, []);
    listeners.get(channel).push(cb);
    return () => {
      const arr = listeners.get(channel);
      if (arr) {
        const i = arr.indexOf(cb);
        if (i >= 0) arr.splice(i, 1);
      }
    };
  }
  window.gravitybox = {
    getState: () => invoke('getState'),
    setConfig: (patch) => invoke('setConfig', patch || {}),
    rpc: (command, payload) => invoke('rpc', { command, payload: payload || {} }),
    getLogs: () => invoke('getLogs'),
    openAntigravity: (opts) => invoke('openAntigravity', opts || {}),
    safeRelaunchAntigravity: () => invoke('safeRelaunchAntigravity'),
    closeAntigravityGracefully: () => invoke('closeAntigravityGracefully'),
    setLoginItem: (enabled) => invoke('setLoginItem', { enabled: Boolean(enabled) }),
    openMainWindow: (tab) => invoke('openMainWindow', { tab: tab || 'overview' }),
    hidePopover: () => invoke('hidePopover'),
    openPath: (targetPath) => invoke('openPath', { path: targetPath || '' }),
    openExternal: (url) => invoke('openExternal', { url: url || '' }),
    copyText: (text) => invoke('copyText', { text: String(text ?? '') }),
    saveJsonDialog: (defaultName, data) => invoke('saveJsonDialog', { defaultName: defaultName || 'gravitybox-export.json', data }),
    checkUpdates: () => invoke('checkUpdates'),
    downloadUpdate: () => invoke('downloadUpdate'),
    cancelUpdate: () => invoke('cancelUpdate'),
    installUpdate: () => invoke('installUpdate'),
    quit: () => invoke('quit'),
    onStatus: (cb) => on('status', cb),
    onConfig: (cb) => on('config', cb),
    onUpdate: (cb) => on('update', cb),
    onNavigate: (cb) => on('navigate', cb),
  };
})();
"#;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TargetView {
    Main,
    Popover,
}

#[derive(Debug)]
enum UserEvent {
    JsRequest {
        target: TargetView,
        raw: String,
    },
    JsResolve {
        target: TargetView,
        req_id: u64,
        ok: bool,
        payload: Value,
    },
    EmitAll {
        channel: &'static str,
        payload: Value,
    },
    ShowMain(String),
    TogglePopover,
    HidePopover,
    TrayClick(TrayIconEvent),
    MenuAction(MenuId),
    RebuildTrayMenu,
    QuitApp,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct AppConfig {
    schema: u32,
    application_channel: String,
    hud_enabled: bool,
    app_language: String,
    quota_refresh_minutes: u64,
    auto_pricing_sync_enabled: bool,
    sync_antigravity_lifecycle: bool,
    auto_update_enabled: bool,
    menu_selected_tab: u32,
    menu_usage_period: u32,
    menu_trend_metric: String,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            schema: 2,
            application_channel: "stable".to_string(),
            hud_enabled: true,
            app_language: "system".to_string(),
            quota_refresh_minutes: 0,
            auto_pricing_sync_enabled: false,
            sync_antigravity_lifecycle: false,
            auto_update_enabled: true,
            menu_selected_tab: 0,
            menu_usage_period: 0,
            menu_trend_metric: "tokens".to_string(),
        }
    }
}

struct SharedState {
    resource_root: PathBuf,
    state_dir: PathBuf,
    local_dir: PathBuf,
    ipc_endpoint: String,
    version: String,
    repo_slug: String,
    system_locale: String,
    i18n_packs: HashMap<String, Value>,
    config: RwLock<AppConfig>,
    latest_status: RwLock<Option<Value>>,
    update_state: RwLock<UpdateState>,
    download_cancel: AtomicBool,
    pending_nav_tab: Mutex<Option<String>>,
    backend: Arc<BackendSupervisor>,
    tray_menu_ids: RwLock<TrayMenuIds>,
}

#[derive(Clone, Default)]
struct TrayMenuIds {
    open_main: String,
    toggle_popover: String,
    open_ag: String,
    check_update: String,
    quit: String,
}

struct ActiveWindow {
    window: Window,
    webview: WebView,
}

fn find_resource_root() -> PathBuf {
    let mut candidates = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.to_path_buf());
            if let Some(p1) = dir.parent() {
                candidates.push(p1.to_path_buf());
                if let Some(p2) = p1.parent() {
                    candidates.push(p2.to_path_buf());
                }
            }
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.clone());
        if let Some(p) = cwd.parent() {
            candidates.push(p.to_path_buf());
        }
    }
    for dir in candidates {
        if dir.join("ui").join("index.html").is_file() && dir.join("dist").join("main.js").is_file() {
            return dir;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn read_pkg_meta(resource_root: &Path) -> (String, String) {
    let fallback_ver = env!("CARGO_PKG_VERSION").to_string();
    let fallback_repo = "KAIKAIKAISER/gravitybox".to_string();
    let Ok(text) = fs::read_to_string(resource_root.join("package.json")) else {
        return (fallback_ver, fallback_repo);
    };
    let Ok(val) = serde_json::from_str::<Value>(&text) else {
        return (fallback_ver, fallback_repo);
    };
    let ver = val
        .get("version")
        .and_then(|v| v.as_str())
        .unwrap_or(&fallback_ver)
        .to_string();
    let raw_repo = val
        .get("repository")
        .and_then(|r| {
            r.as_str()
                .map(|s| s.to_string())
                .or_else(|| r.get("url").and_then(|u| u.as_str()).map(|s| s.to_string()))
        })
        .unwrap_or_default();
    let slug = extract_github_slug(&raw_repo).unwrap_or(fallback_repo);
    (ver, slug)
}

fn extract_github_slug(raw: &str) -> Option<String> {
    let lower = raw.to_ascii_lowercase();
    let idx = lower.find("github.com")?;
    let rest = raw[idx + "github.com".len()..].trim_start_matches(['/', ':']);
    let clean = rest.trim_end_matches(".git").trim_end_matches('/');
    let mut parts = clean.split('/');
    let owner = parts.next()?;
    let repo = parts.next()?;
    if owner.is_empty() || repo.is_empty() {
        None
    } else {
        Some(format!("{owner}/{repo}"))
    }
}

fn load_i18n_packs(resource_root: &Path) -> HashMap<String, Value> {
    let mut map = HashMap::new();
    for code in ["zh-Hans", "en"] {
        let path = resource_root.join("assets").join("i18n").join(format!("{code}.json"));
        if let Ok(raw) = fs::read_to_string(path) {
            if let Ok(v) = serde_json::from_str::<Value>(&raw) {
                map.insert(code.to_string(), v);
            }
        }
    }
    map
}

fn load_config(state_dir: &Path) -> AppConfig {
    let _ = fs::create_dir_all(state_dir);
    let path = state_dir.join("config.json");
    if let Ok(raw) = fs::read_to_string(&path) {
        if let Ok(mut cfg) = serde_json::from_str::<AppConfig>(&raw) {
            cfg.schema = 2;
            cfg.application_channel = "stable".to_string();
            return cfg;
        }
    }
    let cfg = AppConfig::default();
    let _ = fs::write(&path, serde_json::to_string_pretty(&cfg).unwrap_or_default() + "\n");
    cfg
}

fn save_config_to_disk(state_dir: &Path, cfg: &AppConfig) {
    let _ = fs::create_dir_all(state_dir);
    let path = state_dir.join("config.json");
    if let Ok(s) = serde_json::to_string_pretty(cfg) {
        let _ = fs::write(path, s + "\n");
    }
}

impl SharedState {
    fn resolve_active_locale(&self) -> String {
        let cfg = self.config.read().unwrap();
        if cfg.app_language == "zh-Hans" || cfg.app_language == "en" {
            return cfg.app_language.clone();
        }
        if self.system_locale.to_ascii_lowercase().starts_with("zh") {
            "zh-Hans".to_string()
        } else {
            "en".to_string()
        }
    }

    fn t(&self, key: &str, fallback: &str) -> String {
        let loc = self.resolve_active_locale();
        self.i18n_packs
            .get(&loc)
            .and_then(|p| p.get("app"))
            .and_then(|a| a.get(key))
            .and_then(|v| v.as_str())
            .or_else(|| {
                self.i18n_packs
                    .get("en")
                    .and_then(|p| p.get("app"))
                    .and_then(|a| a.get(key))
                    .and_then(|v| v.as_str())
            })
            .unwrap_or(fallback)
            .to_string()
    }

    fn build_tray_menu(&self) -> Menu {
        let menu = Menu::new();
        let m_main = MenuItem::new(self.t("tray.open_main", "打开主界面"), true, None);
        let m_pop = MenuItem::new(self.t("tray.open_popover", "显示快捷浮窗"), true, None);
        let m_ag = MenuItem::new(self.t("sidebar.open_antigravity", "打开 Antigravity"), true, None);
        let m_upd = MenuItem::new(self.t("about.check_update", "检查更新"), true, None);
        let m_quit = MenuItem::new(self.t("tray.quit", "退出 GravityBox"), true, None);

        let ids = TrayMenuIds {
            open_main: m_main.id().0.clone(),
            toggle_popover: m_pop.id().0.clone(),
            open_ag: m_ag.id().0.clone(),
            check_update: m_upd.id().0.clone(),
            quit: m_quit.id().0.clone(),
        };
        *self.tray_menu_ids.write().unwrap() = ids;

        let _ = menu.append(&m_main);
        let _ = menu.append(&m_pop);
        let _ = menu.append(&PredefinedMenuItem::separator());
        let _ = menu.append(&m_ag);
        let _ = menu.append(&m_upd);
        let _ = menu.append(&PredefinedMenuItem::separator());
        let _ = menu.append(&m_quit);
        menu
    }

    fn snapshot_state_json(&self) -> Value {
        let cfg = self.config.read().unwrap().clone();
        let active_locale = self.resolve_active_locale();
        let status = self.latest_status.read().unwrap().clone();
        let update_state = self.update_state.read().unwrap().clone();
        let initial_tab = self.pending_nav_tab.lock().unwrap().take();
        let ag_exe = win32::find_antigravity_exe()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        json!({
            "config": cfg,
            "i18nPacks": self.i18n_packs,
            "activeLocale": active_locale,
            "systemLocale": self.system_locale,
            "initialTab": initial_tab,
            "status": status,
            "updateState": update_state,
            "appInfo": {
                "version": self.version,
                "repoSlug": self.repo_slug,
                "stateDir": self.state_dir.to_string_lossy(),
                "antigravityExe": ag_exe,
                "platform": "win32",
                "arch": "x64",
                "runtime": "rust-webview2",
                "openAtLogin": win32::get_login_item(),
            }
        })
    }
}

fn load_app_icons() -> (Option<TaoIcon>, Option<TrayIcon>) {
    let Ok(dir) = ico::IconDir::read(std::io::Cursor::new(EMBEDDED_ICO)) else {
        return (None, None);
    };
    let entries = dir.entries();
    if entries.is_empty() {
        return (None, None);
    }
    let best_win = entries
        .iter()
        .max_by_key(|e| e.width())
        .and_then(|e| e.decode().ok())
        .and_then(|img| TaoIcon::from_rgba(img.rgba_data().to_vec(), img.width(), img.height()).ok());

    let tray_entry = entries
        .iter()
        .find(|e| e.width() == 32)
        .or_else(|| entries.iter().min_by_key(|e| (e.width() as i32 - 32).abs()));
    let best_tray = tray_entry
        .and_then(|e| e.decode().ok())
        .and_then(|img| TrayIcon::from_rgba(img.rgba_data().to_vec(), img.width(), img.height()).ok());

    (best_win, best_tray)
}

fn mime_for_path(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase().as_str() {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "application/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        "webp" => "image/webp",
        _ => "application/octet-stream",
    }
}

fn serve_custom_asset(resource_root: &Path, req: Request<Vec<u8>>) -> Response<Cow<'static, [u8]>> {
    let raw_path = req.uri().path().trim_start_matches('/');
    let rel_clean: PathBuf = raw_path
        .split('/')
        .filter(|seg| !seg.is_empty() && *seg != "." && *seg != "..")
        .collect();
    let candidate = if rel_clean.as_os_str().is_empty() {
        resource_root.join("ui").join("index.html")
    } else {
        resource_root.join(&rel_clean)
    };

    if candidate.is_file() {
        if let Ok(bytes) = fs::read(&candidate) {
            return Response::builder()
                .status(200)
                .header(CONTENT_TYPE, mime_for_path(&candidate))
                .header("Cache-Control", "no-store")
                .body(Cow::Owned(bytes))
                .unwrap();
        }
    }
    Response::builder()
        .status(404)
        .header(CONTENT_TYPE, "text/plain; charset=utf-8")
        .body(Cow::Borrowed(b"Not Found".as_slice()))
        .unwrap()
}

fn spawn_main_window(
    target_loop: &EventLoopWindowTarget<UserEvent>,
    web_ctx: &mut WebContext,
    shared: &Arc<SharedState>,
    proxy: &EventLoopProxy<UserEvent>,
    win_icon: Option<TaoIcon>,
) -> Option<ActiveWindow> {
    let window = WindowBuilder::new()
        .with_title("GravityBox")
        .with_inner_size(LogicalSize::new(980.0, 680.0))
        .with_min_inner_size(LogicalSize::new(820.0, 560.0))
        .with_window_icon(win_icon)
        .with_drag_and_drop(false)
        .build(target_loop)
        .ok()?;

    let res_root = shared.resource_root.clone();
    let tx = proxy.clone();
    let webview = WebViewBuilder::new_with_web_context(web_ctx)
        .with_initialization_script(INIT_BRIDGE_JS)
        .with_custom_protocol("gravitybox".to_string(), move |_id, req| {
            serve_custom_asset(&res_root, req)
        })
        .with_ipc_handler(move |req| {
            let _ = tx.send_event(UserEvent::JsRequest {
                target: TargetView::Main,
                raw: req.body().clone(),
            });
        })
        .with_url("gravitybox://localhost/ui/index.html")
        .build(&window)
        .ok()?;

    Some(ActiveWindow { window, webview })
}

fn spawn_popover_window(
    target_loop: &EventLoopWindowTarget<UserEvent>,
    web_ctx: &mut WebContext,
    shared: &Arc<SharedState>,
    proxy: &EventLoopProxy<UserEvent>,
) -> Option<ActiveWindow> {
    let width_logical = 424.0;
    let height_logical = 556.0;
    let window = WindowBuilder::new()
        .with_title("GravityBox Tray")
        .with_inner_size(LogicalSize::new(width_logical, height_logical))
        .with_decorations(false)
        .with_resizable(false)
        .with_always_on_top(true)
        .with_skip_taskbar(true)
        .with_undecorated_shadow(true)
        .with_drag_and_drop(false)
        .build(target_loop)
        .ok()?;

    let scale = window.scale_factor();
    let phys_w = (width_logical * scale).round() as i32;
    let phys_h = (height_logical * scale).round() as i32;
    let (wa_l, wa_t, wa_r, wa_b) = win32::work_area_rect();
    let margin = (10.0 * scale).round() as i32;
    let x = (wa_r - phys_w - margin).max(wa_l);
    let y = (wa_b - phys_h - margin).max(wa_t);
    window.set_outer_position(PhysicalPosition::new(x, y));

    let res_root = shared.resource_root.clone();
    let tx = proxy.clone();
    let webview = WebViewBuilder::new_with_web_context(web_ctx)
        .with_initialization_script(INIT_BRIDGE_JS)
        .with_custom_protocol("gravitybox".to_string(), move |_id, req| {
            serve_custom_asset(&res_root, req)
        })
        .with_ipc_handler(move |req| {
            let _ = tx.send_event(UserEvent::JsRequest {
                target: TargetView::Popover,
                raw: req.body().clone(),
            });
        })
        .with_url("gravitybox://localhost/ui/popover.html")
        .build(&window)
        .ok()?;

    let _ = window.set_focus();
    Some(ActiveWindow { window, webview })
}

fn handle_js_request(
    target: TargetView,
    raw: String,
    shared: Arc<SharedState>,
    proxy: EventLoopProxy<UserEvent>,
) {
    let Ok(msg) = serde_json::from_str::<Value>(&raw) else {
        return;
    };
    let req_id = msg.get("reqId").and_then(|v| v.as_u64()).unwrap_or(0);
    let cmd = msg.get("cmd").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let payload = msg.get("payload").cloned().unwrap_or_else(|| json!({}));

    let proxy_res = proxy.clone();
    let resolve = move |ok: bool, val: Value| {
        let _ = proxy_res.send_event(UserEvent::JsResolve {
            target,
            req_id,
            ok,
            payload: val,
        });
    };

    match cmd.as_str() {
        "openMainWindow" => {
            let tab = payload
                .get("tab")
                .and_then(|v| v.as_str())
                .unwrap_or("overview")
                .to_string();
            let _ = proxy.send_event(UserEvent::HidePopover);
            let _ = proxy.send_event(UserEvent::ShowMain(tab));
            resolve(true, json!({ "ok": true }));
        }
        "hidePopover" => {
            let _ = proxy.send_event(UserEvent::HidePopover);
            resolve(true, json!({ "ok": true }));
        }
        "quit" => {
            let _ = proxy.send_event(UserEvent::QuitApp);
            resolve(true, json!({ "ok": true }));
        }
        _ => {
            let proxy_bg = proxy.clone();
            thread::spawn(move || {
                let (ok, val) = execute_bg_command(&cmd, payload, &shared, &proxy_bg);
                let _ = proxy_bg.send_event(UserEvent::JsResolve {
                    target,
                    req_id,
                    ok,
                    payload: val,
                });
            });
        }
    }
}

fn execute_bg_command(
    cmd: &str,
    payload: Value,
    shared: &Arc<SharedState>,
    proxy: &EventLoopProxy<UserEvent>,
) -> (bool, Value) {
    match cmd {
        "getState" => (true, shared.snapshot_state_json()),
        "setConfig" => {
            let mut next = shared.config.write().unwrap();
            if let Some(obj) = payload.as_object() {
                if let Some(v) = obj.get("hudEnabled").and_then(|v| v.as_bool()) {
                    next.hud_enabled = v;
                }
                if let Some(v) = obj.get("appLanguage").and_then(|v| v.as_str()) {
                    next.app_language = v.to_string();
                }
                if let Some(v) = obj.get("quotaRefreshMinutes").and_then(|v| v.as_u64()) {
                    next.quota_refresh_minutes = v;
                }
                if let Some(v) = obj.get("autoPricingSyncEnabled").and_then(|v| v.as_bool()) {
                    next.auto_pricing_sync_enabled = v;
                }
                if let Some(v) = obj.get("syncAntigravityLifecycle").and_then(|v| v.as_bool()) {
                    next.sync_antigravity_lifecycle = v;
                }
                if let Some(v) = obj.get("autoUpdateEnabled").and_then(|v| v.as_bool()) {
                    next.auto_update_enabled = v;
                }
            }
            next.schema = 2;
            next.application_channel = "stable".to_string();
            let snapshot = next.clone();
            drop(next);
            save_config_to_disk(&shared.state_dir, &snapshot);
            let cfg_val = serde_json::to_value(&snapshot).unwrap_or_else(|_| json!({}));
            let _ = proxy.send_event(UserEvent::EmitAll {
                channel: "config",
                payload: cfg_val.clone(),
            });
            let _ = proxy.send_event(UserEvent::RebuildTrayMenu);
            (true, cfg_val)
        }
        "rpc" => {
            let command = payload
                .get("command")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let rpc_payload = payload.get("payload").cloned().unwrap_or_else(|| json!({}));
            let timeout = match command {
                "status" | "ping" | "task_list" => 8_000,
                _ => 120_000,
            };
            let loc = shared.resolve_active_locale();
            shared.backend.ensure_running(&loc, &shared.system_locale);
            match rpc_call(&shared.ipc_endpoint, command, rpc_payload, timeout) {
                Ok(v) => (true, v),
                Err(e) => (true, json!({ "ok": false, "error": e })),
            }
        }
        "getLogs" => (true, json!({ "ok": true, "text": shared.backend.read_recent_logs() })),
        "openAntigravity" => {
            let remote_debug = payload
                .get("remoteDebug")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            match win32::open_antigravity(remote_debug) {
                Ok(()) => (true, json!({ "ok": true })),
                Err(e) => (true, json!({ "ok": false, "error": e })),
            }
        }
        "safeRelaunchAntigravity" => match win32::safe_relaunch_antigravity() {
            Ok(()) => (true, json!({ "ok": true })),
            Err(e) => (true, json!({ "ok": false, "error": e })),
        },
        "closeAntigravityGracefully" => {
            let ok = win32::close_antigravity_gracefully(12_000);
            (true, json!({ "ok": ok }))
        }
        "setLoginItem" => {
            let enabled = payload
                .get("enabled")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            let actual = win32::set_login_item(enabled);
            (true, json!({ "ok": true, "openAtLogin": actual }))
        }
        "openPath" => {
            if let Some(p) = payload.get("path").and_then(|v| v.as_str()) {
                win32::shell_open(p);
            }
            (true, json!({ "ok": true }))
        }
        "openExternal" => {
            if let Some(u) = payload.get("url").and_then(|v| v.as_str()) {
                let low = u.to_ascii_lowercase();
                if low.starts_with("https://") || low.starts_with("http://") {
                    win32::shell_open(u);
                }
            }
            (true, json!({ "ok": true }))
        }
        "copyText" => {
            let text = payload.get("text").and_then(|v| v.as_str()).unwrap_or("");
            match win32::copy_to_clipboard(text) {
                Ok(()) => (true, json!({ "ok": true })),
                Err(e) => (true, json!({ "ok": false, "error": e })),
            }
        }
        "saveJsonDialog" => {
            let default_name = payload
                .get("defaultName")
                .and_then(|v| v.as_str())
                .unwrap_or("gravitybox-export.json");
            let data = payload.get("data").cloned().unwrap_or(Value::Null);
            match win32::save_json_dialog(default_name) {
                Some(path) => {
                    let pretty = serde_json::to_string_pretty(&data).unwrap_or_default() + "\n";
                    match fs::write(&path, pretty) {
                        Ok(()) => (
                            true,
                            json!({ "ok": true, "filePath": path.to_string_lossy() }),
                        ),
                        Err(e) => (true, json!({ "ok": false, "error": e.to_string() })),
                    }
                }
                None => (true, json!({ "ok": false, "canceled": true })),
            }
        }
        "checkUpdates" => {
            let val = run_check_updates(shared, proxy);
            (true, val)
        }
        "downloadUpdate" => {
            let val = run_download_update(shared, proxy);
            (true, val)
        }
        "cancelUpdate" => {
            shared.download_cancel.store(true, Ordering::SeqCst);
            (true, json!({ "ok": true }))
        }
        "installUpdate" => {
            let st = shared.update_state.read().unwrap().clone();
            if let Some(path) = st.downloaded_path {
                if Path::new(&path).is_file() {
                    win32::shell_open(&path);
                    return (true, json!({ "ok": true }));
                }
            }
            if let Some(url) = st.release_url {
                win32::shell_open(&url);
            }
            (true, json!({ "ok": false }))
        }
        _ => (false, json!({ "error": format!("Unknown command: {cmd}") })),
    }
}

fn emit_update_state(shared: &SharedState, proxy: &EventLoopProxy<UserEvent>) -> Value {
    let st = shared.update_state.read().unwrap().clone();
    let v = serde_json::to_value(&st).unwrap_or_else(|_| json!({}));
    let _ = proxy.send_event(UserEvent::EmitAll {
        channel: "update",
        payload: v.clone(),
    });
    v
}

fn run_check_updates(shared: &SharedState, proxy: &EventLoopProxy<UserEvent>) -> Value {
    {
        let mut st = shared.update_state.write().unwrap();
        st.state = "checking".to_string();
        st.error = None;
    }
    emit_update_state(shared, proxy);

    match updater::fetch_latest_release(&shared.repo_slug, &shared.version) {
        Ok(next) => {
            *shared.update_state.write().unwrap() = next;
        }
        Err(e) => {
            let mut st = shared.update_state.write().unwrap();
            st.state = "error".to_string();
            st.error = Some(e);
        }
    }
    emit_update_state(shared, proxy)
}

fn run_download_update(shared: &SharedState, proxy: &EventLoopProxy<UserEvent>) -> Value {
    let snapshot = shared.update_state.read().unwrap().clone();
    let Some(asset_url) = snapshot.asset_url else {
        if let Some(url) = snapshot.release_url {
            win32::shell_open(&url);
        }
        return json!({ "ok": false, "error": "No installer asset" });
    };
    let asset_name = snapshot
        .asset_name
        .unwrap_or_else(|| "GravityBox-Setup.exe".to_string());
    shared.download_cancel.store(false, Ordering::SeqCst);
    {
        let mut st = shared.update_state.write().unwrap();
        st.state = "downloading".to_string();
        st.progress = 0;
        st.error = None;
    }
    emit_update_state(shared, proxy);

    let updates_dir = shared.local_dir.join("updates");
    let mut last_pct: u32 = 0;
    let res = updater::download_and_verify(
        &asset_name,
        &asset_url,
        snapshot.sha256_url.as_deref(),
        &updates_dir,
        &shared.download_cancel,
        |pct| {
            if pct >= last_pct.saturating_add(3) || pct == 100 {
                last_pct = pct;
                shared.update_state.write().unwrap().progress = pct;
                emit_update_state(shared, proxy);
            }
        },
    );

    match res {
        Ok(path) => {
            let mut st = shared.update_state.write().unwrap();
            st.state = "ready".to_string();
            st.progress = 100;
            st.downloaded_path = Some(path.to_string_lossy().into_owned());
            st.error = None;
        }
        Err(e) => {
            let mut st = shared.update_state.write().unwrap();
            if e == "Cancelled" {
                st.state = "available".to_string();
                st.progress = 0;
            } else {
                st.state = "error".to_string();
                st.error = Some(e);
            }
        }
    }
    emit_update_state(shared, proxy)
}

fn start_background_workers(shared: Arc<SharedState>, proxy: EventLoopProxy<UserEvent>) {
    // Worker 1: Backend supervisor + 3s status polling + Antigravity lifecycle monitor
    let s1 = shared.clone();
    let p1 = proxy.clone();
    thread::spawn(move || {
        let init_loc = s1.resolve_active_locale();
        s1.backend.ensure_running(&init_loc, &s1.system_locale);
        let mut ag_seen_running = false;
        loop {
            if win32::is_antigravity_running() {
                ag_seen_running = true;
            } else if ag_seen_running && s1.config.read().unwrap().sync_antigravity_lifecycle {
                let _ = p1.send_event(UserEvent::QuitApp);
                break;
            }

            if !s1.backend.is_alive() {
                let loc = s1.resolve_active_locale();
                s1.backend.spawn_if_needed(&loc, &s1.system_locale);
            }
            if let Ok(status_val) = rpc_call(&s1.ipc_endpoint, "status", json!({}), 4_000) {
                if status_val.get("ok").and_then(|v| v.as_bool()) == Some(true) {
                    *s1.latest_status.write().unwrap() = Some(status_val.clone());
                    let _ = p1.send_event(UserEvent::EmitAll {
                        channel: "status",
                        payload: status_val,
                    });
                }
            }
            thread::sleep(Duration::from_secs(3));
        }
    });

    // Worker 2: Periodic quota refresh + initial auto-update check
    let s2 = shared.clone();
    let p2 = proxy.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(8));
        if s2.config.read().unwrap().auto_update_enabled {
            run_check_updates(&s2, &p2);
        }

        let mut last_refresh = Instant::now();
        loop {
            thread::sleep(Duration::from_secs(30));
            let mins = s2.config.read().unwrap().quota_refresh_minutes;
            if mins > 0 && last_refresh.elapsed() >= Duration::from_secs(mins * 60) {
                last_refresh = Instant::now();
                let _ = rpc_call(&s2.ipc_endpoint, "quota_refresh_start", json!({}), 5_000);
            }
        }
    });
}

fn eval_on_active(win: &Option<ActiveWindow>, script: &str) {
    if let Some(ref active) = win {
        let _ = active.webview.evaluate_script(script);
    }
}

fn main() {
    let Some(_instance_mutex) = win32::acquire_single_instance_or_signal() else {
        return;
    };

    let resource_root = find_resource_root();
    let app_data = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("USERPROFILE").map(|h| PathBuf::from(h).join("AppData").join("Roaming"))
        })
        .unwrap_or_else(|| PathBuf::from("."));
    let local_app_data = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("USERPROFILE").map(|h| PathBuf::from(h).join("AppData").join("Local"))
        })
        .unwrap_or_else(|| app_data.clone());

    let state_dir = app_data.join("GravityBox");
    let local_dir = local_app_data.join("GravityBox");
    let webview_udf = local_dir.join("WebView2");
    let log_dir = local_dir.join("logs");
    let _ = fs::create_dir_all(&state_dir);
    let _ = fs::create_dir_all(&webview_udf);

    let (version, repo_slug) = read_pkg_meta(&resource_root);
    let config = load_config(&state_dir);
    let ipc_endpoint = compute_ipc_endpoint(&state_dir);
    let backend = Arc::new(BackendSupervisor::new(
        resource_root.clone(),
        state_dir.clone(),
        log_dir,
        ipc_endpoint.clone(),
    ));

    let shared = Arc::new(SharedState {
        resource_root,
        state_dir,
        local_dir,
        ipc_endpoint,
        version: version.clone(),
        repo_slug,
        system_locale: win32::system_locale_name(),
        i18n_packs: load_i18n_packs(&find_resource_root()),
        config: RwLock::new(config),
        latest_status: RwLock::new(None),
        update_state: RwLock::new(UpdateState::initial(&version)),
        download_cancel: AtomicBool::new(false),
        pending_nav_tab: Mutex::new(None),
        backend,
        tray_menu_ids: RwLock::new(TrayMenuIds::default()),
    });

    let start_in_tray = std::env::args().any(|a| a == "--tray");
    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();

    let p_show = proxy.clone();
    win32::start_show_main_event_listener(move || {
        let _ = p_show.send_event(UserEvent::ShowMain("overview".to_string()));
    });

    let p_tray = proxy.clone();
    TrayIconEvent::set_event_handler(Some(move |ev| {
        let _ = p_tray.send_event(UserEvent::TrayClick(ev));
    }));
    let p_menu = proxy.clone();
    MenuEvent::set_event_handler(Some(move |ev: MenuEvent| {
        let _ = p_menu.send_event(UserEvent::MenuAction(ev.id));
    }));

    let (win_icon, tray_icon_img) = load_app_icons();
    let mut web_ctx = WebContext::new(Some(webview_udf));
    let mut tray_icon: Option<SysTrayIcon> = None;
    let mut main_win: Option<ActiveWindow> = None;
    let mut popover_win: Option<ActiveWindow> = None;
    let mut last_popover_dismiss = Instant::now() - Duration::from_secs(10);

    start_background_workers(shared.clone(), proxy.clone());

    event_loop.run(move |event, target, control_flow| {
        *control_flow = ControlFlow::Wait;

        match event {
            Event::NewEvents(StartCause::Init) => {
                let menu = shared.build_tray_menu();
                let mut tb = TrayIconBuilder::new()
                    .with_tooltip("GravityBox")
                    .with_menu(Box::new(menu))
                    .with_menu_on_left_click(false);
                if let Some(ref ic) = tray_icon_img {
                    tb = tb.with_icon(ic.clone());
                }
                tray_icon = tb.build().ok();

                if !start_in_tray {
                    main_win = spawn_main_window(target, &mut web_ctx, &shared, &proxy, win_icon.clone());
                }
            }

            Event::UserEvent(ev) => match ev {
                UserEvent::JsRequest { target: view_target, raw } => {
                    handle_js_request(view_target, raw, shared.clone(), proxy.clone());
                }
                UserEvent::JsResolve {
                    target: view_target,
                    req_id,
                    ok,
                    payload,
                } => {
                    let js = format!(
                        "window.__gbResolve && window.__gbResolve({}, {}, {})",
                        req_id,
                        if ok { "true" } else { "false" },
                        serde_json::to_string(&payload).unwrap_or_else(|_| "null".to_string())
                    );
                    match view_target {
                        TargetView::Main => eval_on_active(&main_win, &js),
                        TargetView::Popover => eval_on_active(&popover_win, &js),
                    }
                }
                UserEvent::EmitAll { channel, payload } => {
                    let js = format!(
                        "window.__gbEmit && window.__gbEmit({}, {})",
                        serde_json::to_string(channel).unwrap_or_else(|_| "\"\"".to_string()),
                        serde_json::to_string(&payload).unwrap_or_else(|_| "null".to_string())
                    );
                    eval_on_active(&main_win, &js);
                    eval_on_active(&popover_win, &js);
                }
                UserEvent::ShowMain(tab) => {
                    if let Some(ref aw) = main_win {
                        aw.window.set_minimized(false);
                        aw.window.set_focus();
                        let js = format!(
                            "window.__gbEmit && window.__gbEmit(\"navigate\", {})",
                            serde_json::to_string(&tab).unwrap_or_else(|_| "\"overview\"".to_string())
                        );
                        let _ = aw.webview.evaluate_script(&js);
                    } else {
                        *shared.pending_nav_tab.lock().unwrap() = Some(tab.clone());
                        main_win = spawn_main_window(target, &mut web_ctx, &shared, &proxy, win_icon.clone());
                        if tab != "overview" {
                            let js = format!(
                                "setTimeout(() => window.__gbEmit && window.__gbEmit(\"navigate\", {}), 250)",
                                serde_json::to_string(&tab).unwrap_or_else(|_| "\"overview\"".to_string())
                            );
                            eval_on_active(&main_win, &js);
                        }
                    }
                }
                UserEvent::TogglePopover => {
                    if popover_win.is_some() {
                        popover_win = None;
                        last_popover_dismiss = Instant::now();
                    } else if last_popover_dismiss.elapsed() > Duration::from_millis(220) {
                        popover_win = spawn_popover_window(target, &mut web_ctx, &shared, &proxy);
                    }
                }
                UserEvent::HidePopover => {
                    if popover_win.is_some() {
                        popover_win = None;
                        last_popover_dismiss = Instant::now();
                    }
                }
                UserEvent::TrayClick(tev) => {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = tev
                    {
                        let _ = proxy.send_event(UserEvent::TogglePopover);
                    }
                }
                UserEvent::MenuAction(menu_id) => {
                    let ids = shared.tray_menu_ids.read().unwrap().clone();
                    let id_str = menu_id.0;
                    if id_str == ids.open_main {
                        let _ = proxy.send_event(UserEvent::ShowMain("overview".to_string()));
                    } else if id_str == ids.toggle_popover {
                        let _ = proxy.send_event(UserEvent::TogglePopover);
                    } else if id_str == ids.open_ag {
                        thread::spawn(|| {
                            let _ = win32::open_antigravity(false);
                        });
                    } else if id_str == ids.check_update {
                        let _ = proxy.send_event(UserEvent::ShowMain("about".to_string()));
                        let s = shared.clone();
                        let p = proxy.clone();
                        thread::spawn(move || {
                            run_check_updates(&s, &p);
                        });
                    } else if id_str == ids.quit {
                        let _ = proxy.send_event(UserEvent::QuitApp);
                    }
                }
                UserEvent::RebuildTrayMenu => {
                    if let Some(ref ti) = tray_icon {
                        let menu = shared.build_tray_menu();
                        ti.set_menu(Some(Box::new(menu)));
                    }
                }
                UserEvent::QuitApp => {
                    popover_win = None;
                    main_win = None;
                    tray_icon = None;
                    shared.backend.stop_gracefully();
                    *control_flow = ControlFlow::Exit;
                }
            },

            Event::WindowEvent { window_id, event: win_ev, .. } => {
                let is_main = main_win.as_ref().is_some_and(|w| w.window.id() == window_id);
                let is_pop = popover_win.as_ref().is_some_and(|w| w.window.id() == window_id);

                match win_ev {
                    WindowEvent::CloseRequested => {
                        if is_main {
                            // Drop main WebView2 completely when closing to tray -> zero GUI RAM while idle!
                            main_win = None;
                        } else if is_pop {
                            popover_win = None;
                            last_popover_dismiss = Instant::now();
                        }
                    }
                    WindowEvent::Focused(false) if is_pop => {
                        popover_win = None;
                        last_popover_dismiss = Instant::now();
                    }
                    _ => {}
                }
            }

            _ => {}
        }
    });
}
