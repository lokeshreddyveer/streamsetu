import Foundation

/// Hand written replies in the shape SoundCloud's web interface uses, with invented ids and names. No network and no real content.
enum SoundCloudFixtures {
    /// A full track: progressive MP3, HLS AAC at two rates and an adaptive master playlist, no encryption.
    static let plainTrack = """
    {"kind":"track","id":1001,"title":"Night Drive (Original Mix)","duration":245000,"full_duration":245000,
     "artwork_url":"https://i1.sndcdn.com/artworks-abc-large.jpg","permalink_url":"https://soundcloud.com/nova-fm/night-drive",
     "genre":"Electronic","tag_list":"house","description":"fresh","created_at":"2024-05-01T10:00:00Z","playback_count":5400,
     "streamable":true,"policy":"ALLOW","track_authorization":"auth-1","waveform_url":"https://wave.sndcdn.com/abc_m.json",
     "user":{"id":77,"username":"Nova FM","permalink":"nova-fm","permalink_url":"https://soundcloud.com/nova-fm","avatar_url":"https://i1.sndcdn.com/avatars-x-large.jpg","followers_count":15000,"verified":true},
     "publisher_metadata":{"artist":"Nova FM","isrc":"XX1230000001","explicit":false},
     "media":{"transcodings":[
       {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1001/a/stream/hls","preset":"aac_96k","snipped":false,"format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\\"mp4a.40.5\\""}},
       {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1001/b/stream/progressive","preset":"mp3_0_0","snipped":false,"format":{"protocol":"progressive","mime_type":"audio/mpeg"}},
       {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1001/c/stream/hls","preset":"aac_160k","snipped":false,"format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\\"mp4a.40.2\\""}},
       {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1001/d/stream/hls","preset":"mp3_0_0","snipped":false,"format":{"protocol":"hls","mime_type":"application/x-mpegURL"}}
     ]}}
    """

    /// HLS AAC only (the common case today).
    static let hlsOnlyTrack = """
    {"kind":"track","id":1002,"title":"Slow Tape","duration":180000,"streamable":true,"policy":"ALLOW",
     "user":{"id":78,"username":"Tape Club"},
     "media":{"transcodings":[
       {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1002/a/stream/hls","preset":"aac_160k","format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\\"mp4a.40.2\\""}}
     ]}}
    """

    /// A paid release beside plain listings: an encrypted variant means the whole track is protected.
    static let encryptedTrack = """
    {"kind":"track","id":1003,"title":"Label Hit","duration":200000,"streamable":true,"policy":"MONETIZE",
     "user":{"id":79,"username":"Big Label"},
     "media":{"transcodings":[
       {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1003/a/stream/hls","preset":"aac_160k","format":{"protocol":"hls","mime_type":"audio/mp4"}},
       {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1003/b/stream/ctr-encrypted-hls","preset":"aac_160k","format":{"protocol":"ctr-encrypted-hls","mime_type":"audio/mp4"}}
     ]}}
    """

    /// Only a 30 second preview: snipped flag and the preview address.
    static let snippedTrack = """
    {"kind":"track","id":1004,"title":"Teaser","duration":30000,"full_duration":210000,"streamable":true,"policy":"SNIP",
     "user":{"id":80,"username":"Preview Person"},
     "media":{"transcodings":[
       {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1004/a/preview/hls","preset":"aac_160k","snipped":true,"format":{"protocol":"hls","mime_type":"audio/mp4"}},
       {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1004/b/preview/progressive","preset":"mp3_0_0","snipped":false,"format":{"protocol":"progressive","mime_type":"audio/mpeg"}}
     ]}}
    """

    static let blockedTrack = """
    {"kind":"track","id":1005,"title":"Not Here","duration":120000,"streamable":true,"policy":"BLOCK","user":{"id":81,"username":"Someone"},
     "media":{"transcodings":[]}}
    """

    static let notStreamableTrack = """
    {"kind":"track","id":1006,"title":"Private One","duration":120000,"streamable":false,"policy":"ALLOW","user":{"id":81,"username":"Someone"},
     "media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/media/x/stream/hls","preset":"aac_160k","format":{"protocol":"hls","mime_type":"audio/mp4"}}]}}
    """

    /// A label channel re-uploading: the credited artist differs from the uploader.
    static let labelUpload = """
    {"kind":"track","id":1007,"title":"Moonlight","duration":210000,"streamable":true,"policy":"ALLOW",
     "user":{"id":90,"username":"Deep Records"},"publisher_metadata":{"artist":"Luna Park"},
     "media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/media/x/stream/hls","preset":"aac_160k","format":{"protocol":"hls","mime_type":"audio/mp4"}}]}}
    """

    static func search(next: String? = "https://api-v2.soundcloud.com/search/tracks?q=drive&offset=2&limit=2&linked_partitioning=1") -> String {
        """
        {"collection":[\(plainTrack),\(hlsOnlyTrack),{"kind":"user","id":5,"username":"mixed in"}],
         "total_results":50\(next.map { ",\"next_href\":\"\($0)\"" } ?? "")}
        """
    }

    static let relatedList = """
    {"collection":[\(hlsOnlyTrack),\(plainTrack),\(plainTrack),\(encryptedTrack),\(snippedTrack)]}
    """

    static let playlist = """
    {"kind":"playlist","id":3001,"title":"Late Set","is_album":false,"track_count":3,"permalink_url":"https://soundcloud.com/nova-fm/sets/late-set",
     "user":{"id":77,"username":"Nova FM"},
     "tracks":[{"id":1001,"kind":"track"},{"id":1002,"kind":"track"},\(plainTrack)]}
    """

    static let album = """
    {"kind":"playlist","id":3002,"title":"First Light","is_album":true,"set_type":"album","track_count":2,"release_date":"2024-03-01T00:00:00Z",
     "user":{"id":77,"username":"Nova FM"},"tracks":[]}
    """

    static let resolveUser = """
    {"kind":"user","id":77,"username":"Nova FM","permalink":"nova-fm","followers_count":15000,"verified":true}
    """

    static let streamReply = #"{"url":"https://cf-hls-media.sndcdn.com/playlist/abc.m3u8?Policy=x&expires=4102444800"}"#
    static let previewReply = #"{"url":"https://cf-preview-media.sndcdn.com/preview/0/30/abc.m3u8"}"#

    static let waveform = #"{"width":1800,"height":140,"samples":[0,10,70,140,100,50,20,5,0,30,60,90]}"#

    /// A home page and a script bundle, as the client key is read from them.
    static let homePage = """
    <html><head><script crossorigin src="https://a-v2.sndcdn.com/assets/0-aaa.js"></script>
    <script crossorigin src="https://a-v2.sndcdn.com/assets/1-bbb.js"></script>
    <script src="https://a-v2.sndcdn.com/assets/0-aaa.js"></script></head><body></body></html>
    """
    static let fakeKey = "AbCdEfGhIjKlMnOpQrStUvWxYz012345"
    static let bundleWithKey = "var a=1;e.exports={api:\"x\",client_id:\"\(fakeKey)\",env:\"production\"};"
    static let bundleWithoutKey = "var a=1;e.exports={client_id:\"tooshort\"};"

    static let shortPage = """
    <html><head><link rel="canonical" href="https://soundcloud.com/nova-fm/night-drive"/><meta property="og:url" content="https://soundcloud.com/nova-fm/night-drive"></head></html>
    """

    static let description = """
    DJ set recorded live. Tracklist:
    00:00 Opening Words
    03:45 - Artist One - First Song
    [12:34] Ünïcödé 夜の街
    1. 1:02:03 Last One
    nothing here 99:99
    """
}
