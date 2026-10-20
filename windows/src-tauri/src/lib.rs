//! StreamSetu for Windows: one window with tabs. A tab is either a web page (a WebView2 view) or StreamSetu's own screens (the IPTV player, drawn by the main view).
use serde::Serialize;
use std::sync::Mutex;
use streamsetu_core::{proxy, secrets};
use tauri::webview::{PageLoadEvent, WebviewBuilder};
use tauri::window::WindowBuilder;
use tauri::{Emitter, LogicalPosition, LogicalSize, Manager, WebviewUrl};

const UA: &str = "StreamSetu/0.1 (Windows)";
const MAIN_LABEL: &str = "main";
const UI_LABEL: &str = "ui";

struct ProxyBase(String);
/// The labels of the web page views that are open, so they can be moved and closed together.
#[derive(Default)]
struct Pages(Mutex<Vec<String>>);

#[tauri::command]
fn proxy_base(state: tauri::State<ProxyBase>) -> String { state.0.clone() }

#[tauri::command]
fn secret_set(playlist_id: String, value: String) -> Result<(), String> { secrets::set(&secrets::name_for(&playlist_id), &value) }
#[tauri::command]
fn secret_get(playlist_id: String) -> Result<Option<String>, String> { secrets::get(&secrets::name_for(&playlist_id)) }
#[tauri::command]
fn secret_delete(playlist_id: String) -> Result<(), String> { secrets::delete(&secrets::name_for(&playlist_id)) }

/// Fetches a web address for the player (a playlist, or an Xtream API answer). The page itself cannot, because providers do not allow other sites to read their answers.
#[tauri::command]
async fn fetch_text(url: String) -> Result<String, String> {
    if !(url.starts_with("http://") || url.starts_with("https://")) { return Err("Only web addresses can be opened.".into()); }
    tauri::async_runtime::spawn_blocking(move || {
        let agent = ureq::AgentBuilder::new().timeout_connect(std::time::Duration::from_secs(15)).timeout_read(std::time::Duration::from_secs(90)).user_agent(UA).build();
        let resp = agent.get(&url).call().map_err(|e| match e { ureq::Error::Status(c, _) => format!("The server answered {c}."), other => other.to_string() })?;
        let mut body = String::new();
        std::io::Read::read_to_string(&mut std::io::Read::take(resp.into_reader(), 200 * 1024 * 1024), &mut body).map_err(|e| e.to_string())?;
        Ok(body)
    }).await.map_err(|e| e.to_string())?
}

/// Plays an address in a player installed on this computer (mpv first, then VLC): for the formats a web page cannot play.
#[tauri::command]
fn play_external(url: String) -> Result<String, String> {
    if !(url.starts_with("http://") || url.starts_with("https://")) { return Err("Only web addresses can be played.".into()); }
    let candidates: [(&str, &[&str]); 4] = [
        ("mpv", &[]),
        ("C:\\Program Files\\VideoLAN\\VLC\\vlc.exe", &[]),
        ("C:\\Program Files (x86)\\VideoLAN\\VLC\\vlc.exe", &[]),
        ("vlc", &[]),
    ];
    for (program, extra) in candidates {
        if std::process::Command::new(program).args(extra).arg(&url).spawn().is_ok() { return Ok(program.rsplit('\\').next().unwrap_or(program).to_string()); }
    }
    Err("mpv or VLC is not installed. Install one of them to play this format.".into())
}

#[derive(Clone, Serialize)]
struct PageEvent { label: String, url: String, loading: bool }

fn page_builder(app: &tauri::AppHandle, label: &str, url: &str) -> Result<WebviewBuilder<tauri::Wry>, String> {
    let parsed = url::Url::parse(url).map_err(|e| e.to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") { return Err("Only web pages can be opened here.".into()); }
    let handle = app.clone(); let name = label.to_string();
    Ok(WebviewBuilder::new(label, WebviewUrl::External(parsed))
        .on_page_load(move |wv, payload| {
            let loading = matches!(payload.event(), PageLoadEvent::Started);
            let _ = handle.emit("browser:page", PageEvent { label: name.clone(), url: payload.url().to_string(), loading });
            let _ = wv;
        }))
}

/// Opens a web page as a tab, below the tab strip: `x, y, w, h` are in the window's coordinates.
#[tauri::command]
fn browser_open(app: tauri::AppHandle, pages: tauri::State<Pages>, label: String, url: String, x: f64, y: f64, w: f64, h: f64) -> Result<(), String> {
    let window = app.get_window(MAIN_LABEL).ok_or("The window is not ready.")?;
    let builder = page_builder(&app, &label, &url)?;
    window.add_child(builder, LogicalPosition::new(x, y), LogicalSize::new(w, h)).map_err(|e| e.to_string())?;
    pages.0.lock().unwrap().push(label);
    Ok(())
}

#[tauri::command]
fn browser_bounds(app: tauri::AppHandle, label: String, x: f64, y: f64, w: f64, h: f64) -> Result<(), String> {
    let wv = app.get_webview(&label).ok_or("No such tab.")?;
    wv.set_position(LogicalPosition::new(x, y)).map_err(|e| e.to_string())?;
    wv.set_size(LogicalSize::new(w, h)).map_err(|e| e.to_string())
}

#[tauri::command]
fn browser_show(app: tauri::AppHandle, label: String, visible: bool) -> Result<(), String> {
    let wv = app.get_webview(&label).ok_or("No such tab.")?;
    if visible { wv.show() } else { wv.hide() }.map_err(|e| e.to_string())
}

#[tauri::command]
fn browser_close(app: tauri::AppHandle, pages: tauri::State<Pages>, label: String) -> Result<(), String> {
    pages.0.lock().unwrap().retain(|l| l != &label);
    if let Some(wv) = app.get_webview(&label) { wv.close().map_err(|e| e.to_string())?; }
    Ok(())
}

#[tauri::command]
fn browser_navigate(app: tauri::AppHandle, label: String, url: String) -> Result<(), String> {
    let parsed = url::Url::parse(&url).map_err(|e| e.to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") { return Err("Only web pages can be opened here.".into()); }
    app.get_webview(&label).ok_or("No such tab.")?.navigate(parsed).map_err(|e| e.to_string())
}

/// back, forward, reload or stop on a tab.
#[tauri::command]
fn browser_action(app: tauri::AppHandle, label: String, action: String) -> Result<(), String> {
    let script = match action.as_str() { "back" => "history.back()", "forward" => "history.forward()", "reload" => "location.reload()", "stop" => "window.stop()", _ => return Err("Unknown action.".into()) };
    app.get_webview(&label).ok_or("No such tab.")?.eval(script).map_err(|e| e.to_string())
}

pub fn run() {
    let proxy = proxy::start(UA.to_string()).expect("the local stream proxy could not start");
    tauri::Builder::default()
        .manage(ProxyBase(proxy.base.clone()))
        .manage(Pages::default())
        .setup(|app| {
            let window = WindowBuilder::new(app, MAIN_LABEL).title("StreamSetu").inner_size(1280.0, 800.0).min_inner_size(900.0, 600.0).build()?;
            let size = window.inner_size()?.to_logical::<f64>(window.scale_factor()?);
            // The main view (the tab strip and StreamSetu's own screens) fills the window; web pages sit on top of it, below the tab strip.
            window.add_child(WebviewBuilder::new(UI_LABEL, WebviewUrl::App("index.html".into())), LogicalPosition::new(0.0, 0.0), size)?;
            let handle = app.handle().clone();
            window.on_window_event(move |event| {
                if let tauri::WindowEvent::Resized(physical) = event {
                    if let (Some(win), Some(ui)) = (handle.get_window(MAIN_LABEL), handle.get_webview(UI_LABEL)) {
                        if let Ok(scale) = win.scale_factor() {
                            let logical = physical.to_logical::<f64>(scale);
                            let _ = ui.set_size(logical);
                            let _ = handle.emit("window:resized", (logical.width, logical.height));
                        }
                    }
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![proxy_base, secret_set, secret_get, secret_delete, fetch_text, play_external, browser_open, browser_bounds, browser_show, browser_close, browser_navigate, browser_action])
        .run(tauri::generate_context!())
        .expect("StreamSetu could not start");
}
