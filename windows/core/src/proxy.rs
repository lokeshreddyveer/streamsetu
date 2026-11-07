use crate::policy::{self, Allow, Refused};
use crate::rewrite::{looks_like_hls, rewrite_hls};
use std::io::Read;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tiny_http::{Header, Response, Server, StatusCode};

/// A small server on this computer that fetches a stream for the web view. IPTV servers do not send the headers a web page needs to read a stream (CORS), so the player asks this
/// server, which asks the provider and passes the answer back with those headers added.
///
/// It is not open to whoever can reach the port. Every address starts with a secret made when the app starts (`/s/<token>/p?u=`), so a web page or program that only finds the port
/// gets a 403. `Host` must be this server, `Origin` (when sent) must be one of the app's own pages, and where it fetches from follows `policy`: no loopback, no local network, no
/// logins in addresses, redirects checked at every step, except for hosts the person has put in a connection. The number of simultaneous requests is capped.
pub struct Proxy {
    /// Where the player sends addresses to be fetched: `http://127.0.0.1:<port>/s/<token>`. `rewrite` puts this in front of every address in a playlist, so the secret travels with them.
    pub base: String,
    pub port: u16,
    pub token: String,
    pub allow: Allow,
}

pub struct Config {
    pub user_agent: String,
    /// The origins of the app's own pages. A request from any other origin is refused.
    pub allowed_origins: Vec<String>,
    pub max_connections: usize,
}

fn header(name: &str, value: &str) -> Option<Header> { Header::from_bytes(name.as_bytes(), value.as_bytes()).ok() }

fn query_param(url: &str, key: &str) -> Option<String> {
    let parsed = url::Url::parse(&format!("http://local{url}")).ok()?;
    parsed.query_pairs().find(|(k, _)| k == key).map(|(_, v)| v.into_owned())
}

/// 256 bits from the operating system's random generator, as hex.
fn new_token() -> std::io::Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes).map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Equal strings, in time that does not depend on where they first differ.
fn same_secret(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let mut diff = (a.len() != b.len()) as u8;
    for i in 0..a.len().max(b.len()) { diff |= a.get(i).copied().unwrap_or(0) ^ b.get(i).copied().unwrap_or(0xff); }
    diff == 0
}

struct Slot(Arc<AtomicUsize>);
impl Drop for Slot { fn drop(&mut self) { self.0.fetch_sub(1, Ordering::SeqCst); } }

struct Shared { token: String, host: String, origins: Vec<String>, base: String, agent: ureq::Agent }

pub fn start(cfg: Config, allow: Allow) -> std::io::Result<Proxy> {
    let server = Server::http("127.0.0.1:0").map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
    let port = server.server_addr().to_ip().map(|a| a.port()).unwrap_or(0);
    let token = new_token()?;
    let base = format!("http://127.0.0.1:{port}/s/{token}");
    let shared = Arc::new(Shared { token: token.clone(), host: format!("127.0.0.1:{port}"), origins: cfg.allowed_origins, base: base.clone(), agent: policy::agent(&allow, &cfg.user_agent, Duration::from_secs(12), Duration::from_secs(45)) });
    let server = Arc::new(server);
    let active = Arc::new(AtomicUsize::new(0));
    let max = cfg.max_connections.max(1);
    thread::spawn(move || {
        for request in server.incoming_requests() {
            if active.load(Ordering::SeqCst) >= max { let _ = request.respond(Response::empty(503)); continue; }
            active.fetch_add(1, Ordering::SeqCst);
            let slot = Slot(active.clone()); let shared = shared.clone();
            thread::spawn(move || { let _slot = slot; handle(request, &shared); });
        }
    });
    Ok(Proxy { base, port, token, allow })
}

fn request_header(request: &tiny_http::Request, name: &str) -> Option<String> {
    request.headers().iter().find(|h| h.field.as_str().as_str().eq_ignore_ascii_case(name)).map(|h| h.value.as_str().to_string())
}

fn refuse(request: tiny_http::Request, code: u16) { let _ = request.respond(Response::empty(code)); }

fn handle(request: tiny_http::Request, sh: &Shared) {
    // 1. The right door: this server's own name, the secret in the path, and an origin that is one of the app's pages.
    if request_header(&request, "Host").as_deref() != Some(sh.host.as_str()) { return refuse(request, 403); }
    let path = request.url().split('?').next().unwrap_or("").to_string();
    let mut parts = path.trim_start_matches('/').split('/');
    let (Some("s"), Some(token), Some("p"), None) = (parts.next(), parts.next(), parts.next(), parts.next()) else { return refuse(request, 403) };
    if !same_secret(token, &sh.token) { return refuse(request, 403); }
    let origin = request_header(&request, "Origin");
    if let Some(o) = &origin { if !sh.origins.iter().any(|a| a == o) { return refuse(request, 403); } }
    let cors: Vec<Option<Header>> = match &origin {
        Some(o) => vec![header("Access-Control-Allow-Origin", o), header("Vary", "Origin"), header("Access-Control-Allow-Headers", "Range"), header("Access-Control-Expose-Headers", "Content-Length, Content-Range, Content-Type"), header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")],
        None => vec![],
    };
    if request.method() == &tiny_http::Method::Options { let _ = request.respond(add_cors(&cors, Response::empty(204))); return; }

    // 2. What to fetch, and whether the rules allow it (checked again by the resolver on the address actually used, and on every redirect).
    let Some(target) = query_param(request.url(), "u") else { let _ = request.respond(add_cors(&cors, Response::empty(400))); return };
    let range = request_header(&request, "Range");
    let (resp, final_url) = match policy::get(&sh.agent, &target, range.as_deref()) {
        Ok(ok) => ok,
        Err(Refused::Blocked) => { let _ = request.respond(add_cors(&cors, Response::empty(403))); return; }
        Err(Refused::Unreachable) => { let _ = request.respond(add_cors(&cors, Response::empty(502))); return; }
        Err(_) => { let _ = request.respond(add_cors(&cors, Response::empty(400))); return; }
    };

    let status = resp.status();
    let content_type = resp.content_type().to_string();
    let content_range = resp.header("Content-Range").map(str::to_string);
    let length = resp.header("Content-Length").and_then(|v| v.parse::<usize>().ok());
    let mut reader = resp.into_reader();
    // A playlist is small: read it, rewrite its addresses, send it. Anything else streams straight through.
    let mut head = [0u8; 8];
    let n = read_some(&mut reader, &mut head);
    if looks_like_hls(&content_type, &head[..n]) && length.map_or(true, |l| l < 4_000_000) {
        let mut rest = Vec::new();
        let _ = reader.take(4_000_000).read_to_end(&mut rest);
        let mut all = head[..n].to_vec(); all.extend_from_slice(&rest);
        let text = String::from_utf8_lossy(&all).to_string();
        let body = rewrite_hls(&text, final_url.as_str(), &sh.base).into_bytes();
        let mut r = Response::from_data(body).with_status_code(StatusCode(status));
        if let Some(h) = header("Content-Type", "application/vnd.apple.mpegurl") { r.add_header(h); }
        let _ = request.respond(add_cors(&cors, r));
    } else {
        let chained = std::io::Cursor::new(head[..n].to_vec()).chain(reader);
        let mut r = Response::new(StatusCode(status), vec![], chained, length, None);
        if let Some(h) = header("Content-Type", if content_type.is_empty() { "application/octet-stream" } else { &content_type }) { r.add_header(h); }
        if let Some(range) = content_range { if let Some(h) = header("Content-Range", &range) { r.add_header(h); } }
        if let Some(h) = header("Accept-Ranges", "bytes") { r.add_header(h); }
        let _ = request.respond(add_cors(&cors, r));
    }
}

fn add_cors<R: Read>(cors: &[Option<Header>], mut r: Response<R>) -> Response<R> {
    for h in cors.iter().flatten() { r.add_header(h.clone()); }
    r
}

fn read_some(r: &mut dyn Read, buf: &mut [u8]) -> usize {
    let mut got = 0;
    while got < buf.len() { match r.read(&mut buf[got..]) { Ok(0) | Err(_) => break, Ok(n) => got += n } }
    got
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rewrite::proxied;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};

    const APP: &str = "http://tauri.localhost";

    /// A stand-in provider on this computer: a playlist, a stream, two kinds of redirect, and a path that never answers.
    fn provider() -> (String, u16) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                thread::spawn(move || {
                    let mut s = stream; let mut buf = [0u8; 2048]; let n = s.read(&mut buf).unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]).to_string();
                    let first = req.lines().next().unwrap_or("").to_string();
                    if first.starts_with("GET /hang") { thread::sleep(Duration::from_secs(20)); return; }
                    if first.starts_with("GET /redir-local") { let _ = write!(s, "HTTP/1.1 302 Found\r\nLocation: http://localhost:{port}/video.ts\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return; }
                    if first.starts_with("GET /loop") { let _ = write!(s, "HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return; }
                    if first.starts_with("GET /redir-ok") { let _ = write!(s, "HTTP/1.1 302 Found\r\nLocation: /video.ts\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return; }
                    let (ct, body): (&str, Vec<u8>) = if first.starts_with("GET /list.m3u8") { ("application/vnd.apple.mpegurl", b"#EXTM3U\n#EXTINF:4,\nseg1.ts\n".to_vec()) } else { ("video/mp2t", vec![0x47; 5000]) };
                    let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                    let _ = s.write_all(&body);
                });
            }
        });
        (format!("http://127.0.0.1:{port}"), port)
    }

    fn proxy(listed: &[&str], max: usize) -> Proxy {
        let allow = Allow::default(); for h in listed { allow.add(h); }
        start(Config { user_agent: "test".into(), allowed_origins: vec![APP.into()], max_connections: max }, allow).unwrap()
    }

    struct Answer { status: u16, headers: String, body: Vec<u8> }

    /// One raw request, so the test controls `Host` and `Origin` exactly.
    fn raw(port: u16, path: &str, host: &str, extra: &[(&str, &str)]) -> Answer {
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut req = format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n");
        for (k, v) in extra { req.push_str(&format!("{k}: {v}\r\n")); }
        req.push_str("\r\n");
        s.write_all(req.as_bytes()).unwrap();
        let mut all = Vec::new(); let _ = s.read_to_end(&mut all);
        let split = all.windows(4).position(|w| w == b"\r\n\r\n").map(|i| i + 4).unwrap_or(all.len());
        let head = String::from_utf8_lossy(&all[..split]).to_string();
        let status = head.split(' ').nth(1).and_then(|c| c.parse().ok()).unwrap_or(0);
        Answer { status, headers: head.to_ascii_lowercase(), body: all[split..].to_vec() }
    }

    fn via(p: &Proxy, target: &str) -> String { proxied(&p.base, target).trim_start_matches(&format!("http://127.0.0.1:{}", p.port)).to_string() }
    fn ask(p: &Proxy, target: &str, extra: &[(&str, &str)]) -> Answer { raw(p.port, &via(p, target), &format!("127.0.0.1:{}", p.port), extra) }

    #[test]
    fn a_stream_passes_through_and_a_playlist_is_rewritten_with_the_secret_kept() {
        let (up, _) = provider(); let p = proxy(&["127.0.0.1"], 8);
        let a = ask(&p, &format!("{up}/video.ts"), &[]);
        assert_eq!(a.status, 200); assert_eq!(a.body.len(), 5000);
        let a = ask(&p, &format!("{up}/list.m3u8"), &[]);
        let text = String::from_utf8(a.body).unwrap();
        assert_eq!(a.status, 200);
        assert!(text.contains(&format!("{}/p?u=", p.base)), "every address in the playlist must carry the secret: {text}");
        assert!(text.contains("seg1%2Ets"));
    }

    #[test]
    fn the_secret_is_long_random_and_different_each_time() {
        let (a, b) = (proxy(&[], 2), proxy(&[], 2));
        assert_eq!(a.token.len(), 64); assert!(a.token.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a.token, b.token);
    }

    #[test]
    fn a_request_without_the_secret_or_with_a_wrong_one_is_refused() {
        let (up, _) = provider(); let p = proxy(&["127.0.0.1"], 8);
        let host = format!("127.0.0.1:{}", p.port);
        let enc = |t: &str| format!("u={}", percent_encoding::utf8_percent_encode(t, percent_encoding::NON_ALPHANUMERIC));
        let target = format!("{up}/video.ts");
        assert_eq!(raw(p.port, &format!("/p?{}", enc(&target)), &host, &[]).status, 403, "the old address without a secret");
        assert_eq!(raw(p.port, &format!("/s/{}/p?{}", "0".repeat(64), enc(&target)), &host, &[]).status, 403, "a wrong secret");
        assert_eq!(raw(p.port, &format!("/s/{}/p?{}", &p.token[..63], enc(&target)), &host, &[]).status, 403, "a secret that is one character short");
        assert_eq!(raw(p.port, &format!("/s/{}/other?{}", p.token, enc(&target)), &host, &[]).status, 403, "another path");
        assert_eq!(raw(p.port, &format!("/s/{}/p/extra?{}", p.token, enc(&target)), &host, &[]).status, 403, "a longer path");
        assert_eq!(raw(p.port, &format!("/s/{}/p?{}", p.token, enc(&target)), &host, &[]).status, 200, "the right secret works");
    }

    #[test]
    fn a_wrong_host_name_is_refused_which_stops_dns_rebinding() {
        let (up, _) = provider(); let p = proxy(&["127.0.0.1"], 8);
        assert_eq!(raw(p.port, &via(&p, &format!("{up}/video.ts")), "attacker.example", &[]).status, 403);
        assert_eq!(raw(p.port, &via(&p, &format!("{up}/video.ts")), &format!("attacker.example:{}", p.port), &[]).status, 403);
        assert_eq!(raw(p.port, &via(&p, &format!("{up}/video.ts")), &format!("localhost:{}", p.port), &[]).status, 403, "localhost is another name, not this server's");
    }

    #[test]
    fn a_page_from_another_origin_is_refused_and_the_app_s_own_origin_is_answered_by_name() {
        let (up, _) = provider(); let p = proxy(&["127.0.0.1"], 8);
        assert_eq!(ask(&p, &format!("{up}/video.ts"), &[("Origin", "https://evil.example")]).status, 403);
        assert_eq!(ask(&p, &format!("{up}/video.ts"), &[("Origin", "null")]).status, 403);
        let a = ask(&p, &format!("{up}/video.ts"), &[("Origin", APP)]);
        assert_eq!(a.status, 200);
        assert!(a.headers.contains(&format!("access-control-allow-origin: {}", APP)), "{}", a.headers);
        assert!(!a.headers.contains("access-control-allow-origin: *"), "the wildcard is gone");
    }

    #[test]
    fn this_computer_is_not_reachable_unless_the_host_is_in_a_connection() {
        let (up, _) = provider();
        assert_eq!(ask(&proxy(&[], 8), &format!("{up}/video.ts"), &[]).status, 403, "loopback, not listed");
        assert_eq!(ask(&proxy(&["127.0.0.1"], 8), &format!("{up}/video.ts"), &[]).status, 200, "loopback, listed");
    }

    #[test]
    fn the_local_network_and_cloud_metadata_are_refused() {
        let p = proxy(&[], 8);
        for t in ["http://192.168.1.1/admin", "http://10.0.0.1/", "http://169.254.169.254/latest/meta-data/", "http://[::1]/", "http://[fd00::1]/", "http://0.0.0.0:1/"] {
            assert_eq!(ask(&p, t, &[]).status, 403, "{t}");
        }
    }

    #[test]
    fn a_redirect_to_a_place_that_is_not_allowed_is_refused_at_that_step() {
        let (up, _) = provider(); let p = proxy(&["127.0.0.1"], 8);
        assert_eq!(ask(&p, &format!("{up}/redir-ok"), &[]).status, 200, "a redirect inside the allowed host is followed");
        assert_eq!(ask(&p, &format!("{up}/redir-local"), &[]).status, 403, "a redirect to another name for this computer is not");
        assert_eq!(ask(&p, &format!("{up}/loop"), &[]).status, 403, "a redirect that never ends stops after a few steps");
    }

    #[test]
    fn only_web_addresses_without_a_login_are_fetched() {
        let (up, port) = provider(); let p = proxy(&["127.0.0.1"], 8);
        assert_eq!(ask(&p, "file:///etc/passwd", &[]).status, 400);
        assert_eq!(ask(&p, "ftp://example.com/x", &[]).status, 400);
        assert_eq!(ask(&p, &format!("http://user:pw@127.0.0.1:{port}/video.ts"), &[]).status, 400);
        assert_eq!(raw(p.port, &format!("/s/{}/p", p.token), &format!("127.0.0.1:{}", p.port), &[]).status, 400, "no address at all");
        let _ = up;
    }

    #[test]
    fn simultaneous_requests_are_capped() {
        let (up, _) = provider(); let p = proxy(&["127.0.0.1"], 2);
        let mut open = vec![];
        for _ in 0..2 {
            let mut s = TcpStream::connect(("127.0.0.1", p.port)).unwrap();
            write!(s, "GET {} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n\r\n", via(&p, &format!("{up}/hang")), p.port).unwrap();
            open.push(s);
        }
        thread::sleep(Duration::from_millis(400));
        assert_eq!(ask(&p, &format!("{up}/video.ts"), &[]).status, 503, "the third is turned away while two are in use");
    }
}
