//! Playlist passwords live in the system's credential store (Windows Credential Manager), never in a file or in the web view's storage.
const SERVICE: &str = "StreamSetu";

fn entry(name: &str) -> Result<keyring::Entry, String> { keyring::Entry::new(SERVICE, name).map_err(|e| e.to_string()) }

pub fn set(name: &str, value: &str) -> Result<(), String> { entry(name)?.set_password(value).map_err(|e| e.to_string()) }

pub fn get(name: &str) -> Result<Option<String>, String> {
    match entry(name)?.get_password() { Ok(v) => Ok(Some(v)), Err(keyring::Error::NoEntry) => Ok(None), Err(e) => Err(e.to_string()) }
}

pub fn delete(name: &str) -> Result<(), String> {
    match entry(name)?.delete_credential() { Ok(()) | Err(keyring::Error::NoEntry) => Ok(()), Err(e) => Err(e.to_string()) }
}

/// A name no other playlist uses, from the playlist's id.
pub fn name_for(playlist_id: &str) -> String { format!("playlist:{playlist_id}") }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_are_per_playlist() { assert_eq!(name_for("a1"), "playlist:a1"); assert_ne!(name_for("a"), name_for("b")); }
}
