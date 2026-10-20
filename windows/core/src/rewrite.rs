use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
use url::Url;

/// The address a stream is fetched through: the local proxy, with the real address inside.
pub fn proxied(base: &str, target: &str) -> String {
    format!("{base}/p?u={}", utf8_percent_encode(target, NON_ALPHANUMERIC))
}

/// Rewrites an HLS playlist so every address in it (segments, other playlists, keys, maps) goes through the proxy, resolving relative addresses against where the playlist came from.
pub fn rewrite_hls(body: &str, playlist_url: &str, proxy_base: &str) -> String {
    let Ok(base) = Url::parse(playlist_url) else { return body.to_string() };
    let abs = |s: &str| -> String { base.join(s.trim()).map(|u| proxied(proxy_base, u.as_str())).unwrap_or_else(|_| s.to_string()) };
    let mut out = String::with_capacity(body.len() + body.len() / 4);
    for line in body.lines() {
        let t = line.trim();
        if t.is_empty() { out.push('\n'); continue; }
        if let Some(rest) = t.strip_prefix('#') {
            // URI="..." attributes: #EXT-X-KEY, #EXT-X-MAP, #EXT-X-MEDIA, #EXT-X-I-FRAME-STREAM-INF
            if let Some(i) = rest.find("URI=\"") {
                let start = i + 5;
                if let Some(len) = rest[start..].find('"') {
                    let (head, tail) = (&rest[..start], &rest[start + len..]);
                    out.push('#'); out.push_str(head); out.push_str(&abs(&rest[start..start + len])); out.push_str(tail); out.push('\n');
                    continue;
                }
            }
            out.push_str(line); out.push('\n');
        } else {
            out.push_str(&abs(t)); out.push('\n');
        }
    }
    out
}

pub fn looks_like_hls(content_type: &str, first_bytes: &[u8]) -> bool {
    let ct = content_type.to_ascii_lowercase();
    ct.contains("mpegurl") || first_bytes.starts_with(b"#EXTM3U")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segments_and_keys_go_through_the_proxy_with_relative_addresses_resolved() {
        let pl = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"keys/k1.bin\"\n#EXTINF:6,\nseg/1.ts\n#EXTINF:6,\nhttp://other.example/2.ts\n";
        let out = rewrite_hls(pl, "http://host.example/live/stream.m3u8", "http://127.0.0.1:9");
        assert!(out.contains("URI=\"http://127.0.0.1:9/p?u=http%3A%2F%2Fhost%2Eexample%2Flive%2Fkeys%2Fk1%2Ebin\""));
        assert!(out.contains("/p?u=http%3A%2F%2Fhost%2Eexample%2Flive%2Fseg%2F1%2Ets"));
        assert!(out.contains("/p?u=http%3A%2F%2Fother%2Eexample%2F2%2Ets"));
        assert!(out.starts_with("#EXTM3U\n"));
    }

    #[test]
    fn plain_tags_and_blank_lines_are_kept() {
        let out = rewrite_hls("#EXTM3U\n#EXT-X-VERSION:3\n\n#EXTINF:4,\na.ts\n", "http://h/x.m3u8", "http://p");
        assert!(out.contains("#EXT-X-VERSION:3\n\n#EXTINF:4,\n"));
    }

    #[test]
    fn a_playlist_is_recognised_by_type_or_by_its_first_line() {
        assert!(looks_like_hls("application/vnd.apple.mpegurl", b""));
        assert!(looks_like_hls("text/plain", b"#EXTM3U\n"));
        assert!(!looks_like_hls("video/mp2t", b"\x47\x40"));
    }
}
