use crate::rewrite::{looks_like_hls, rewrite_hls};
use std::io::Read;
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tiny_http::{Header, Response, Server, StatusCode};

/// A small server on this computer that fetches a stream for the web view. IPTV servers do not send the headers a web page needs to read a stream (CORS), so the player asks this
/// server, which asks the provider and passes the answer back with those headers added. It listens only on 127.0.0.1, on a port chosen when the app starts.
pub struct Proxy { pub base: String }

fn header(name: &str, value: &str) -> Option<Header> { Header::from_bytes(name.as_bytes(), value.as_bytes()).ok() }

fn query_param(url: &str, key: &str) -> Option<String> {
    let parsed = url::Url::parse(&format!("http://local{url}")).ok()?;
    parsed.query_pairs().find(|(k, _)| k == key).map(|(_, v)| v.into_owned())
}

pub fn start(user_agent: String) -> std::io::Result<Proxy> {
    let server = Server::http("127.0.0.1:0").map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
    let port = server.server_addr().to_ip().map(|a| a.port()).unwrap_or(0);
    let base = format!("http://127.0.0.1:{port}");
    let server = Arc::new(server);
    let agent = ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(12)).timeout_read(Duration::from_secs(45)).user_agent(&user_agent).build();
    let me = base.clone();
    thread::spawn(move || {
        for request in server.incoming_requests() {
            let agent = agent.clone(); let me = me.clone();
            thread::spawn(move || handle(request, &agent, &me));
        }
    });
    Ok(Proxy { base })
}

fn handle(request: tiny_http::Request, agent: &ureq::Agent, me: &str) {
    let cors = [header("Access-Control-Allow-Origin", "*"), header("Access-Control-Allow-Headers", "*"), header("Access-Control-Expose-Headers", "Content-Length, Content-Range, Content-Type"), header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")];
    if request.method() == &tiny_http::Method::Options { let _ = request.respond(add_cors(&cors, Response::empty(204))); return; }
    let Some(target) = query_param(request.url(), "u") else { let _ = request.respond(add_cors(&cors, Response::empty(400))); return };
    // Only web addresses: the proxy must never be a way to read files on this computer.
    if !(target.starts_with("http://") || target.starts_with("https://")) { let _ = request.respond(add_cors(&cors, Response::empty(400))); return; }
    let mut up = agent.get(&target);
    for h in request.headers() {
        let n = h.field.as_str().as_str().to_ascii_lowercase();
        if n == "range" { up = up.set("Range", h.value.as_str()); }
    }
    match up.call() {
        Ok(resp) | Err(ureq::Error::Status(_, resp)) => {
            let status = resp.status();
            let content_type = resp.content_type().to_string();
            let range = resp.header("Content-Range").map(str::to_string);
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
                let body = rewrite_hls(&text, &target, me).into_bytes();
                let mut r = Response::from_data(body).with_status_code(StatusCode(status));
                if let Some(h) = header("Content-Type", "application/vnd.apple.mpegurl") { r.add_header(h); }
                let _ = request.respond(add_cors(&cors, r));
            } else {
                let chained = std::io::Cursor::new(head[..n].to_vec()).chain(reader);
                let mut r = Response::new(StatusCode(status), vec![], chained, length, None);
                if let Some(h) = header("Content-Type", if content_type.is_empty() { "application/octet-stream" } else { &content_type }) { r.add_header(h); }
                if let Some(range) = range { if let Some(h) = header("Content-Range", &range) { r.add_header(h); } }
                if let Some(h) = header("Accept-Ranges", "bytes") { r.add_header(h); }
                let _ = request.respond(add_cors(&cors, r));
            }
        }
        Err(_) => { let _ = request.respond(add_cors(&cors, Response::empty(502))); }
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
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// A stand-in provider: one playlist and one stream.
    fn provider() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                thread::spawn(move || {
                    let mut s = stream; let mut buf = [0u8; 2048]; let n = s.read(&mut buf).unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]).to_string();
                    let (ct, body): (&str, Vec<u8>) = if req.starts_with("GET /list.m3u8") { ("application/vnd.apple.mpegurl", b"#EXTM3U\n#EXTINF:4,\nseg1.ts\n".to_vec()) } else { ("video/mp2t", vec![0x47; 5000]) };
                    let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                    let _ = s.write_all(&body);
                });
            }
        });
        format!("http://{addr}")
    }

    fn get(url: &str) -> (u16, String, Vec<u8>) {
        let r = ureq::get(url).call().unwrap_or_else(|e| match e { ureq::Error::Status(_, r) => r, _ => panic!("{e}") });
        let status = r.status(); let cors = r.header("Access-Control-Allow-Origin").unwrap_or("").to_string();
        let mut body = Vec::new(); r.into_reader().read_to_end(&mut body).unwrap();
        (status, cors, body)
    }

    #[test]
    fn a_stream_passes_through_with_cors_and_a_playlist_is_rewritten() {
        let up = provider();
        let p = start("test".into()).unwrap();
        let (s, cors, body) = get(&format!("{}/p?u={}", p.base, crate::rewrite::proxied("", &format!("{up}/video.ts")).trim_start_matches("/p?u=")));
        assert_eq!(s, 200); assert_eq!(cors, "*"); assert_eq!(body.len(), 5000);
        let (s, _, pl) = get(&crate::rewrite::proxied(&p.base, &format!("{up}/list.m3u8")));
        let text = String::from_utf8(pl).unwrap();
        assert_eq!(s, 200); assert!(text.contains(&format!("{}/p?u=", p.base))); assert!(text.contains("seg1%2Ets"));
    }

    #[test]
    fn only_web_addresses_are_fetched() {
        let p = start("test".into()).unwrap();
        let (s, _, _) = get(&format!("{}/p?u=file%3A%2F%2F%2Fetc%2Fpasswd", p.base));
        assert_eq!(s, 400);
        let (s, _, _) = get(&format!("{}/p", p.base));
        assert_eq!(s, 400);
    }
}
