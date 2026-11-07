//! Where the app may fetch from. The relay and `fetch_text` both go through here, so one rule applies everywhere: only http(s) addresses without a login in them, never this
//! computer or the home network, unless the person has put that host in a connection (a provider on the home network is legitimate). The check is made on the address the connection
//! is actually made to, and again on every redirect, so a name that points somewhere else a moment later, or an address that redirects, gets no further.
use std::collections::HashSet;
use std::io::Read;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs};
use std::sync::{Arc, RwLock};
use std::time::Duration;

/// Hosts the person has put in a connection. Only the app's own pages can add to it.
#[derive(Clone, Default)]
pub struct Allow(Arc<RwLock<HashSet<String>>>);

impl Allow {
    pub fn add(&self, host: &str) { if let Ok(mut set) = self.0.write() { set.insert(host.trim().to_ascii_lowercase()); } }
    pub fn contains(&self, host: &str) -> bool { self.0.read().map(|s| s.contains(&host.trim_matches(|c| c == '[' || c == ']').to_ascii_lowercase())).unwrap_or(false) }
}

fn v4_blocked(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    ip.is_loopback() || ip.is_unspecified() || ip.is_private() || ip.is_link_local() || ip.is_multicast() || ip.is_broadcast() || ip.is_documentation()
        || (o[0] == 100 && (64..128).contains(&o[1]))      // carrier-grade NAT, 100.64.0.0/10
        || o[0] == 0 || o[0] >= 240                         // "this network" and reserved
}

fn v6_blocked(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() { return v4_blocked(v4); }
    let s = ip.segments();
    ip.is_loopback() || ip.is_unspecified() || ip.is_multicast()
        || (s[0] & 0xfe00) == 0xfc00                        // unique local, fc00::/7
        || (s[0] & 0xffc0) == 0xfe80                        // link-local, fe80::/10
}

/// An address that is this computer, this network, or otherwise not the public internet.
pub fn ip_blocked(ip: IpAddr) -> bool { match ip { IpAddr::V4(v) => v4_blocked(v), IpAddr::V6(v) => v6_blocked(v) } }

/// Looks a host up and keeps only the addresses the policy allows; the connection is made to exactly those, so there is no gap between the check and the use.
pub struct SafeResolver { pub allow: Allow }

impl ureq::Resolver for SafeResolver {
    fn resolve(&self, netloc: &str) -> std::io::Result<Vec<SocketAddr>> {
        let host = netloc.rsplit_once(':').map(|(h, _)| h).unwrap_or(netloc);
        let all: Vec<SocketAddr> = netloc.to_socket_addrs()?.collect();
        if self.allow.contains(host) { return Ok(all); }
        let ok: Vec<SocketAddr> = all.into_iter().filter(|a| !ip_blocked(a.ip())).collect();
        if ok.is_empty() { Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "That address is on this computer or network, which is not allowed.")) } else { Ok(ok) }
    }
}

#[derive(Debug, PartialEq)]
pub enum Refused { NotWeb, HasLogin, NoHost, Blocked, Unreachable }

/// The part of the rule that needs no lookup: web addresses only, no login in the address.
pub fn check_url(url: &url::Url) -> Result<(), Refused> {
    if !matches!(url.scheme(), "http" | "https") { return Err(Refused::NotWeb); }
    if !url.username().is_empty() || url.password().is_some() { return Err(Refused::HasLogin); }
    if url.host_str().is_none() { return Err(Refused::NoHost); }
    Ok(())
}

pub fn agent(allow: &Allow, user_agent: &str, connect: Duration, read: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new().redirects(0).resolver(SafeResolver { allow: allow.clone() }).timeout_connect(connect).timeout_read(read).user_agent(user_agent).build()
}

pub const MAX_HOPS: usize = 5;

/// A GET that follows redirects itself, so every hop meets the same rules. `range` is passed on when given.
pub fn get(agent: &ureq::Agent, start: &str, range: Option<&str>) -> Result<(ureq::Response, url::Url), Refused> {
    let mut current = url::Url::parse(start).map_err(|_| Refused::NotWeb)?;
    for _ in 0..=MAX_HOPS {
        check_url(&current)?;
        let mut req = agent.get(current.as_str());
        if let Some(r) = range { req = req.set("Range", r); }
        let resp = match req.call() { Ok(r) => r, Err(ureq::Error::Status(_, r)) => r, Err(ureq::Error::Transport(t)) => return Err(if t.to_string().contains("not allowed") { Refused::Blocked } else { Refused::Unreachable }) };
        if (300..400).contains(&resp.status()) && resp.status() != 304 {
            if let Some(loc) = resp.header("Location") { current = current.join(loc).map_err(|_| Refused::NotWeb)?; continue; }
        }
        return Ok((resp, current));
    }
    Err(Refused::Blocked)
}

/// The text of a web address, read up to `limit` bytes, under the same rules as the relay.
pub fn fetch_text(allow: &Allow, user_agent: &str, url: &str, limit: u64) -> Result<String, String> {
    let agent = agent(allow, user_agent, Duration::from_secs(15), Duration::from_secs(90));
    let (resp, _) = get(&agent, url, None).map_err(|r| match r {
        Refused::NotWeb => "Only web addresses can be opened.".to_string(),
        Refused::HasLogin => "Put the username and password in the connection, not in the address.".to_string(),
        Refused::NoHost | Refused::Unreachable => "That address could not be reached.".to_string(),
        Refused::Blocked => "That address is on this computer or network. Add it as a connection first.".to_string(),
    })?;
    if resp.status() >= 400 { return Err(format!("The server answered {}.", resp.status())); }
    let mut body = String::new();
    resp.into_reader().take(limit).read_to_string(&mut body).map_err(|e| e.to_string())?;
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> IpAddr { s.parse().unwrap() }

    #[test]
    fn this_computer_and_the_local_network_are_blocked() {
        for s in ["127.0.0.1", "127.8.8.8", "0.0.0.0", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254", "100.64.0.1", "224.0.0.1", "255.255.255.255",
                  "::1", "::", "fe80::1", "fd00::1", "fc12::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:192.168.1.1"] {
            assert!(ip_blocked(ip(s)), "{s} should be blocked");
        }
    }

    #[test]
    fn public_addresses_are_not_blocked() {
        for s in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "172.32.0.1", "100.128.0.1", "2606:4700:4700::1111", "::ffff:8.8.8.8"] { assert!(!ip_blocked(ip(s)), "{s} should be allowed"); }
    }

    #[test]
    fn only_web_addresses_without_a_login_pass() {
        let u = |s: &str| url::Url::parse(s).unwrap();
        assert_eq!(check_url(&u("http://a.example/x")), Ok(()));
        assert_eq!(check_url(&u("https://a.example/x")), Ok(()));
        assert_eq!(check_url(&u("file:///etc/passwd")), Err(Refused::NotWeb));
        assert_eq!(check_url(&u("ftp://a.example/x")), Err(Refused::NotWeb));
        assert_eq!(check_url(&u("http://user:pw@a.example/x")), Err(Refused::HasLogin));
        assert_eq!(check_url(&u("http://user@a.example/x")), Err(Refused::HasLogin));
    }

    #[test]
    fn a_host_in_a_connection_is_allowed_even_on_the_local_network() {
        let allow = Allow::default();
        let r = SafeResolver { allow: allow.clone() };
        assert!(ureq::Resolver::resolve(&r, "127.0.0.1:80").is_err());
        allow.add("127.0.0.1");
        assert!(ureq::Resolver::resolve(&r, "127.0.0.1:80").is_ok());
        assert!(ureq::Resolver::resolve(&r, "localhost:80").is_err(), "a different name for the same computer is a different host");
    }
}
