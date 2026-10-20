# Sync on this network

Devices on the same Wi-Fi keep favorites, Watch Later, collections and resume points in step. There is no server and no account: the devices talk to each other directly. iCloud sync on the Apple apps is separate and keeps working.

## What is sent

| Record | Key | Value |
|---|---|---|
| `fav` | `[sourceKey, kind, providerId, list]` (`list` is `favorites` or `later`) | `{"at": ms}` the time it was added, which is also its place in the list |
| `prog` | `[sourceKey, kind, providerId]` (`kind` is `movie` or `episode`) | `{"pos": seconds, "dur": seconds, "done": bool, "series": providerSeriesId or null}` |
| `col` | `[collectionId]` | `{"name": text, "scope": kind}` |
| `colitem` | `[collectionId, sourceKey, kind, providerId]` | `{"at": ms}` |
| `now` | `[deviceId]` | `{"title": text, "pos": seconds, "dev": deviceName, "src": sourceKey, "kind": kind, "prov": providerId}` what that device is playing; `del` when it stopped or is watching privately. Shown on the other devices' Home for a few minutes and never stored. A device that does not know `now` ignores it. |

Every record also has `ts` (milliseconds of the last change) and `del` (true when it was removed). The newer `ts` wins; on a tie the receiver keeps what it has.

`sourceKey` is the first 16 hex characters of SHA-256 of the playlist's address, lower-cased, without `http://` or `https://`, and without trailing slashes. The same playlist on two devices gets the same key, so no logins and no playlist addresses are exchanged. Items of a playlist the other device does not have are ignored, and kept as they are.

`kind` is `channel`, `movie`, `series` or `episode`.

## Finding a device

Each app advertises `_streamsetu-sync._tcp` while sync is on, with the text records `id` (the device id) and `name`. Apps browse for the same type. Nothing is sent to a device that is not paired.

## The connection

TCP. Every message is a frame: 4 bytes, big endian, the length of the body (at most 8 MiB), then the body.

1. The connecting device (initiator) sends a `hello`, and the other (responder) answers with its own: `{"t":"hello","v":1,"pub":base64,"name":text,"nonce":base64 of 16 random bytes}`. `pub` is the device's long-term P-256 public key, uncompressed (65 bytes, `04 || X || Y`).
2. Both work out `z`, the 32-byte ECDH shared secret, and the session key `K = HKDF-SHA256(ikm = z, salt = nonceI || nonceR, info = "streamsetu-sync-v1 session", length 32)`.
3. From here every frame body is AES-256-GCM: the nonce is 12 bytes, `direction (4 bytes, 0 initiator to responder, 1 the other way) || counter (8 bytes, big endian, from 0)`, the body is `ciphertext || 16-byte tag`, no associated data.
4. A device is trusted when its `pub` was confirmed in pairing. A trusted peer goes straight to syncing. An unknown peer is refused (`{"t":"reject","why":"not-paired"}`) unless the responder is showing its "Add a device" screen.
5. Pairing: both show the same 6 digits, from `HKDF-SHA256(ikm = z, salt = pubI || pubR, info = "streamsetu-sync-v1 sas", length 4)` read as a big-endian number modulo 1,000,000, padded with zeros. When the person on each device has confirmed they match, each sends `{"t":"pair","ok":true}` and, once it has sent and received one, stores the other's `pub` and name as trusted. Declining sends `{"t":"pair","ok":false}`.
6. Sync: the initiator sends `{"t":"state","records":[...]}` with everything it has, the responder applies it and answers with its own `state`, the initiator applies that and sends `{"t":"bye"}`. Both sides send everything, so one exchange makes them equal.

A device id is the first 16 hex characters of SHA-256 of its public key.
