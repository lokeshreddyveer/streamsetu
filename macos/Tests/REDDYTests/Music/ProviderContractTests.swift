import Testing
import Foundation
@testable import REDDY

// Offline contract tests. The canned replies below were captured from the live services and trimmed (images, mirrors and unused fields
// dropped, encrypted fields replaced by a marker). No network is used.

private let audiusTracks = #"""
{"data": [{"id": "w7Bap", "title": "Bohemian Rhapsody (cover)", "duration": 367, "play_count": 1029, "isrc": "QZHNA1914360", "permalink": "/jmb/bohemian-rhapsody-cover-142836", "is_streamable": true, "is_delete": false, "is_unlisted": false, "is_stream_gated": false, "parental_warning_type": null, "access": {"stream": true, "download": true}, "release_date": "2020-10-29T04:40:10Z", "artwork": {"150x150": "https://v.monophonic.digital/content/QmaBGZH9am5R4qAPMCsjJZ55J4hW1H3CUfpvNNLVpsTY1b/150x150.jpg", "480x480": "https://v.monophonic.digital/content/QmaBGZH9am5R4qAPMCsjJZ55J4hW1H3CUfpvNNLVpsTY1b/480x480.jpg", "1000x1000": "https://v.monophonic.digital/content/QmaBGZH9am5R4qAPMCsjJZ55J4hW1H3CUfpvNNLVpsTY1b/1000x1000.jpg"}, "user": {"id": "nQJZR", "name": "Jean-Marc Boulier", "handle": "jmb", "profile_picture": {"1000x1000": "https://audius-creator-3.theblueprint.xyz/content/Qmd198uuqtuGSQXhvey6zYVwU1gjr2HtYT9hWsu8vwPHSJ/1000x1000.jpg", "150x150": "https://audius-creator-3.theblueprint.xyz/content/Qmd198uuqtuGSQXhvey6zYVwU1gjr2HtYT9hWsu8vwPHSJ/150x150.jpg", "480x480": "https://audius-creator-3.theblueprint.xyz/content/Qmd198uuqtuGSQXhvey6zYVwU1gjr2HtYT9hWsu8vwPHSJ/480x480.jpg"}}}, {"id": "gb3Pp", "title": "Queen Bohemian Rhapsody kikechacin (Bateria) & Chupetas de Boroncafon (2)", "duration": 349, "play_count": 2247, "isrc": null, "permalink": "/kikechacin/queen-bohemian-rhapsody-kikechacin-bateria-chupetas-de-boroncafon-2", "is_streamable": true, "is_delete": false, "is_unlisted": false, "is_stream_gated": false, "parental_warning_type": null, "access": {"stream": true, "download": true}, "release_date": "2022-09-03T16:00:00Z", "artwork": {"150x150": "https://audius-creator-16.theblueprint.xyz/content/QmXngyv5mggAT7XxaXK6aN2TMHSyJrx7mEvC1pwyGDAGPK/150x150.jpg", "480x480": "https://audius-creator-16.theblueprint.xyz/content/QmXngyv5mggAT7XxaXK6aN2TMHSyJrx7mEvC1pwyGDAGPK/480x480.jpg", "1000x1000": "https://audius-creator-16.theblueprint.xyz/content/QmXngyv5mggAT7XxaXK6aN2TMHSyJrx7mEvC1pwyGDAGPK/1000x1000.jpg"}, "user": {"id": "jjNOo", "name": "kikechacin", "handle": "kikechacin", "profile_picture": {"1000x1000": "https://v.monophonic.digital/content/QmZNggWMdy4Sw5vdFxajyjdsqb7WJ7WrMUdPB4us4ywzJD/1000x1000.jpg", "150x150": "https://v.monophonic.digital/content/QmZNggWMdy4Sw5vdFxajyjdsqb7WJ7WrMUdPB4us4ywzJD/150x150.jpg", "480x480": "https://v.monophonic.digital/content/QmZNggWMdy4Sw5vdFxajyjdsqb7WJ7WrMUdPB4us4ywzJD/480x480.jpg"}}}]}
"""#

private let audiusUser = #"""
{"data": {"id": "nQJZR", "name": "Jean-Marc Boulier", "handle": "jmb", "follower_count": 57, "bio": "Self-taught multi-instrumentalist and vocalist.", "profile_picture": {"1000x1000": "https://cn0.mainnet.audiusindex.org/content/Qmd198uuqtuGSQXhvey6zYVwU1gjr2HtYT9hWsu8vwPHSJ/1000x1000.jpg", "150x150": "https://cn0.mainnet.audiusindex.org/content/Qmd198uuqtuGSQXhvey6zYVwU1gjr2HtYT9hWsu8vwPHSJ/150x150.jpg", "480x480": "https://cn0.mainnet.audiusindex.org/content/Qmd198uuqtuGSQXhvey6zYVwU1gjr2HtYT9hWsu8vwPHSJ/480x480.jpg"}}}
"""#

private let audiusPlaylist = #"""
{"data": [{"id": "WEkgwwv", "playlist_name": "Queen", "is_album": false, "is_private": false, "is_delete": false, "track_count": 5, "permalink": "/harvey_twyman/playlist/queen", "description": "", "artwork": {"150x150": "https://audius-creator-8.theblueprint.xyz/content/QmfV7d5oYKgpJ9Xz3ysyxgPZEM4q56CJQWXSCiavPENi97/150x150.jpg", "480x480": "https://audius-creator-8.theblueprint.xyz/content/QmfV7d5oYKgpJ9Xz3ysyxgPZEM4q56CJQWXSCiavPENi97/480x480.jpg", "1000x1000": "https://audius-creator-8.theblueprint.xyz/content/QmfV7d5oYKgpJ9Xz3ysyxgPZEM4q56CJQWXSCiavPENi97/1000x1000.jpg"}, "user": {"id": "k2N3X", "name": "Harvey Twyman"}}]}
"""#

private let audiusAlbums = #"""
{"data": {"albums": [{"id": "L5EOM", "playlist_name": "A Moment Apart (Deluxe Edition)", "is_album": true, "is_delete": false, "release_date": "2021-11-16T01:41:15Z", "track_count": 25, "permalink": "/odesza/album/a-moment-apart-deluxe-edition-79946", "artwork": {"150x150": "https://audius-content-10.figment.io/content/QmWqUcZu6LVtxyKNHT4xNYyTzFCAgwRtYx4QgyzFnWoarb/150x150.jpg", "480x480": "https://audius-content-10.figment.io/content/QmWqUcZu6LVtxyKNHT4xNYyTzFCAgwRtYx4QgyzFnWoarb/480x480.jpg", "1000x1000": "https://audius-content-10.figment.io/content/QmWqUcZu6LVtxyKNHT4xNYyTzFCAgwRtYx4QgyzFnWoarb/1000x1000.jpg"}, "user": {"id": "2oNg1", "name": "ODESZA"}}], "tracks": [], "users": [], "playlists": []}}
"""#

private let saavnSearch = #"""
{"total": 301, "start": 1, "results": [{"id": "nHs_0eEA", "title": "Kaavaalaa", "subtitle": "Shilpa Rao, Anirudh Ravichander, Arunraja Kamaraj - Jailer", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/kaavaalaa/HiAYbkRVcnI", "image": "https://c.saavncdn.com/187/Jailer-Tamil-2023-20230728081443-150x150.jpg", "language": "tamil", "year": "2023", "play_count": "21387180", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Anirudh Ravichander, Shilpa Rao, Arunraja Kamaraj", "album_id": "47094777", "album": "Jailer", "label": "Sun Pictures", "label_id": null, "origin": "search", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/jailer/LSe0d94xZgE_", "duration": "190", "rights": {"code": "1", "cacheable": "true", "delete_cached_object": "false", "reason": "Pro Only"}, "cache_state": "false", "has_lyrics": "true", "has_trivia": "false", "starred": "false", "artistMap": {"primary_artists": [{"id": "455148", "name": "Shilpa Rao", "image": "https://c.saavncdn.com/artists/Shilpa_Rao_002_20230321111415_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/shilpa-rao-songs/IVd,BmJX7sA_"}, {"id": "455663", "name": "Anirudh Ravichander", "image": "https://c.saavncdn.com/artists/Anirudh_Ravichander_003_20260121134149_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/anirudh-ravichander-songs/lBzQd8c-xCY_"}]}, "release_date": null, "label_url": "/label/sun-pictures-albums/", "vcode": "010910621998213", "vlink": "https://jiotunepreview.jio.com/content/Converted/010910621957263.mp3", "triller_available": false, "request_jiotune_flag": false, "webp": "true", "lyrics_id": ""}}, {"id": "aX5LBX0y", "title": "Kaavaalaa (From &quot;Jailer&quot;)", "subtitle": "Shilpa Rao, Anirudh Ravichander, Arunraja Kamaraj - Kaavaalaa (From &quot;Jailer&quot;)", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/kaavaalaa-from-jailer/ETBefTZoB0o", "image": "https://c.saavncdn.com/183/Kaavaalaa-From-Jailer-Tamil-2023-20230708073100-150x150.jpg", "language": "tamil", "year": "2023", "play_count": "21387140", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Shilpa Rao, Anirudh Ravichander, Arunraja Kamaraj", "album_id": "46483690", "album": "Kaavaalaa (From &quot;Jailer&quot;)", "label": "Sun Pictures", "label_id": null, "origin": "search", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/kaavaalaa-from-jailer/VFIpJzKB32s_", "duration": "190", "rights": {"code": "1", "cacheable": "true", "delete_cached_object": "false", "reason": "Pro Only"}, "cache_state": "false", "has_lyrics": "true", "has_trivia": "false", "starred": "false", "artistMap": {"primary_artists": [{"id": "455148", "name": "Shilpa Rao", "image": "https://c.saavncdn.com/artists/Shilpa_Rao_002_20230321111415_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/shilpa-rao-songs/IVd,BmJX7sA_"}, {"id": "455663", "name": "Anirudh Ravichander", "image": "https://c.saavncdn.com/artists/Anirudh_Ravichander_003_20260121134149_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/anirudh-ravichander-songs/lBzQd8c-xCY_"}]}, "release_date": null, "label_url": "/label/sun-pictures-albums/", "vcode": "010910621998213", "vlink": "https://jiotunepreview.jio.com/content/Converted/010910621957263.mp3", "triller_available": false, "request_jiotune_flag": false, "webp": "true", "lyrics_id": ""}}]}
"""#

private let saavnSong = #"""
{"songs": [{"id": "aRZbUYD7", "title": "Tum Hi Ho", "subtitle": "Mithoon, Arijit Singh - Aashiqui 2", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/tum-hi-ho/EToxUyFpcwQ", "image": "https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-150x150.jpg", "language": "hindi", "year": "2013", "play_count": "376267157", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Mithoon", "album_id": "1139549", "album": "Aashiqui 2", "label": "T-Series", "label_id": "34297", "origin": "none", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/aashiqui-2/-iNdCmFNV9o_", "duration": "262", "rights": {"code": "1", "cacheable": "true", "delete_cached_object": "false", "reason": "Pro Only"}, "cache_state": "false", "has_lyrics": "false", "has_trivia": true, "starred": "false", "artistMap": {"primary_artists": [{"id": "702592", "name": "Mithoon", "image": "https://c.saavncdn.com/artists/Mithoon_002_20200908073735_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/mithoon-songs/nQKQiNRsTKs_"}, {"id": "459320", "name": "Arijit Singh", "image": "https://c.saavncdn.com/artists/Arijit_Singh_004_20241118063717_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/arijit-singh-songs/LlRWpHzy3Hk_"}]}, "release_date": "2013-04-04", "label_url": "/label/t-series-albums/6DLuXO3VoTo_", "vcode": "010910092464548", "vlink": "https://jiotunepreview.jio.com/content/Converted/010910092419390.mp3", "triller_available": false, "request_jiotune_flag": false, "webp": "false"}}]}
"""#

private let saavnAlbum = #"""
{"id": "1139549", "title": "Aashiqui 2", "subtitle": "Jeet Gannguli,  Mithoon,  Ankit Tiwari", "type": "album", "perma_url": "https://www.jiosaavn.com/album/aashiqui-2/-iNdCmFNV9o_", "image": "https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-150x150.jpg", "language": "hindi", "year": "2013", "list_count": "10", "more_info": {"artistMap": {"primary_artists": [{"id": "464912", "name": "Jeet Gannguli", "image": "https://c.saavncdn.com/artists/Jeet_Gannguli_003_20241209065157_150x150.jpg"}, {"id": "702592", "name": " Mithoon", "image": "https://c.saavncdn.com/artists/Mithoon_002_20200908073735_150x150.jpg"}, {"id": "484852", "name": " Ankit Tiwari", "image": "https://c.saavncdn.com/artists/Ankit_Tiwari_002_20241004072220_150x150.jpg"}]}}, "list": [{"id": "aRZbUYD7", "title": "Tum Hi Ho", "subtitle": "Mithoon, Arijit Singh - Aashiqui 2", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/tum-hi-ho/EToxUyFpcwQ", "image": "https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-150x150.jpg", "language": "hindi", "year": "2013", "play_count": "376267425", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Mithoon", "album_id": "1139549", "album": "Aashiqui 2", "label": "T-Series", "label_id": "34297", "origin": "album", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/aashiqui-2/-iNdCmFNV9o_", "duration": "262", "rights": {"code": "1", "cacheable": "true", "delete_cached_object": "false", "reason": "Pro Only"}, "cache_state": "", "has_lyrics": "true", "has_trivia": "1", "starred": "false", "artistMap": {"primary_artists": [{"id": "702592", "name": "Mithoon", "image": "https://c.saavncdn.com/artists/Mithoon_002_20200908073735_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/mithoon-songs/nQKQiNRsTKs_"}, {"id": "459320", "name": "Arijit Singh", "image": "https://c.saavncdn.com/artists/Arijit_Singh_004_20241118063717_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/arijit-singh-songs/LlRWpHzy3Hk_"}]}, "release_date": "2013-04-04", "label_url": "/label/t-series-albums/6DLuXO3VoTo_", "vcode": "010910092464548", "vlink": "https://jiotunepreview.jio.com/content/Converted/010910092419390.mp3", "triller_available": false, "request_jiotune_flag": false, "webp": "false", "lyrics_id": ""}}, {"id": "f8mUyKki", "title": "Sunn Raha Hai (Male)", "subtitle": "Ankit Tiwari - Aashiqui 2", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/sunn-raha-hai-male/FlAGZA17XFo", "image": "https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-150x150.jpg", "language": "hindi", "year": "2013", "play_count": "63018182", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Ankit Tiwari", "album_id": "1139549", "album": "Aashiqui 2", "label": "T-Series", "label_id": "34297", "origin": "album", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/aashiqui-2/-iNdCmFNV9o_", "duration": "390", "rights": {"code": "1", "cacheable": "true", "delete_cached_object": "false", "reason": "Pro Only"}, "cache_state": "", "has_lyrics": "true", "has_trivia": "1", "starred": "false", "artistMap": {"primary_artists": [{"id": "484852", "name": "Ankit Tiwari", "image": "https://c.saavncdn.com/artists/Ankit_Tiwari_002_20241004072220_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/ankit-tiwari-songs/eHCWDfgAqlg_"}]}, "release_date": "2013-04-04", "label_url": "/label/t-series-albums/6DLuXO3VoTo_", "vcode": "010910090123970", "vlink": "https://jiotunepreview.jio.com/content/Converted/010910090136715.mp3", "triller_available": false, "request_jiotune_flag": false, "webp": "false", "lyrics_id": ""}}, {"id": "fY2ah9K7", "title": "Chahun Main Ya Naa", "subtitle": "Arijit Singh, Palak Muchhal - Aashiqui 2", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/chahun-main-ya-naa/FjFZUBwJfAQ", "image": "https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-150x150.jpg", "language": "hindi", "year": "2013", "play_count": "129584894", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Jeet Gannguli", "album_id": "1139549", "album": "Aashiqui 2", "label": "T-Series", "label_id": "34297", "origin": "album", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/aashiqui-2/-iNdCmFNV9o_", "duration": "304", "rights": {"code": "1", "cacheable": "true", "delete_cached_object": "false", "reason": "Pro Only"}, "cache_state": "", "has_lyrics": "true", "has_trivia": "false", "starred": "false", "artistMap": {"primary_artists": [{"id": "459320", "name": "Arijit Singh", "image": "https://c.saavncdn.com/artists/Arijit_Singh_004_20241118063717_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/arijit-singh-songs/LlRWpHzy3Hk_"}, {"id": "467309", "name": "Palak Muchhal", "image": "https://c.saavncdn.com/artists/Palak_Muchhal_004_20250422120342_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/palak-muchhal-songs/9RWBvFQhPxw_"}]}, "release_date": "2013-04-04", "label_url": "/label/t-series-albums/6DLuXO3VoTo_", "vcode": "010910090345159", "vlink": "https://jiotunepreview.jio.com/content/Converted/010910090411597.mp3", "triller_available": false, "request_jiotune_flag": false, "webp": "false", "lyrics_id": ""}}]}
"""#

private let saavnArtist = #"""
{"artistId": "459320", "name": "Arijit Singh", "image": "https://c.saavncdn.com/artists/Arijit_Singh_004_20241118063717_150x150.jpg", "follower_count": "109923760", "type": "artist", "bio": "[{\"text\": \"Indian playback singer.\", \"title\": \"Bio\"}]", "topSongs": [{"id": "vZugSjIh", "title": "Ve Maahi", "subtitle": "Arijit Singh, Asees Kaur - Arijit Singh Revisited", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/ve-maahi/BjIeVidafls", "image": "https://c.saavncdn.com/937/Arijit-Singh-Revisited-Hindi-2026-20261119142731-150x150.jpg", "language": "hindi", "year": "2026", "play_count": "", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Tanishk Bagchi", "album_id": "83861099", "album": "Arijit Singh Revisited", "label": "Zee Music Company", "label_id": null, "origin": "song", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/arijit-singh-revisited/jqtcnCYCWds_", "duration": "223", "rights": {"code": "1", "cacheable": "true", "delete_cached_object": "false", "reason": "Pro Only"}, "cache_state": "false", "has_lyrics": "false", "has_trivia": "false", "starred": "false", "artistMap": {"primary_artists": [{"id": "459320", "name": "Arijit Singh", "image": "https://c.saavncdn.com/artists/Arijit_Singh_004_20241118063717_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/arijit-singh-songs/LlRWpHzy3Hk_"}, {"id": "706985", "name": "Asees Kaur", "image": "https://c.saavncdn.com/artists/Asees_Kaur_007_20250303070610_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/asees-kaur-songs/3LZ-9DxxiH8_"}]}, "release_date": null, "label_url": "/label/zee-music-company-albums/", "vcode": "010910440956330", "vlink": "https://jiotunepreview.jio.com/content/Converted/010910440911918.mp3", "triller_available": false, "request_jiotune_flag": false, "webp": "true"}}, {"id": "rUeGnhsN", "title": "Naina Banjare", "subtitle": "Arijit Singh - Arijit Singh Revisited", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/naina-banjare/Aj0OdhpYRH0", "image": "https://c.saavncdn.com/937/Arijit-Singh-Revisited-Hindi-2026-20261119142731-150x150.jpg", "language": "hindi", "year": "2026", "play_count": "", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Vishal Bhardwaj", "album_id": "83861099", "album": "Arijit Singh Revisited", "label": "Zee Music Company", "label_id": null, "origin": "song", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/arijit-singh-revisited/jqtcnCYCWds_", "duration": "211", "rights": {"code": "1", "cacheable": "true", "delete_cached_object": "false", "reason": "Pro Only"}, "cache_state": "false", "has_lyrics": "false", "has_trivia": "false", "starred": "false", "artistMap": {"primary_artists": [{"id": "459320", "name": "Arijit Singh", "image": "https://c.saavncdn.com/artists/Arijit_Singh_004_20241118063717_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/arijit-singh-songs/LlRWpHzy3Hk_"}]}, "release_date": null, "label_url": "/label/zee-music-company-albums/", "vcode": "010910440875438", "vlink": "https://jiotunepreview.jio.com/content/Converted/010910440831018.mp3", "triller_available": false, "request_jiotune_flag": false, "webp": "true"}}], "topAlbums": []}
"""#

private let saavnArtistAlbums = #"""
{"artistId": "459320", "name": "Arijit Singh", "topAlbums": {"albums": [{"id": "82395349", "title": "Soft Love Hindi Songs", "subtitle": "Jyotica Tangri, Arijit Singh, Jonita Gandhi, Darshan Raval", "type": "album", "perma_url": "https://www.jiosaavn.com/album/soft-love-hindi-songs/RGC7Ttp4NQY_", "image": "https://c.saavncdn.com/544/Soft-Love-Hindi-Songs-Hindi-2026-20261021182859-150x150.jpg", "year": "2026", "language": "hindi", "more_info": {"song_count": "5"}}, {"id": "82258605", "title": "Midnight Romance Bollywood", "subtitle": "Arijit Singh, Parampara Tandon, Amit Trivedi, Jasleen Royal", "type": "album", "perma_url": "https://www.jiosaavn.com/album/midnight-romance-bollywood/j-v8fn1ogxE_", "image": "https://c.saavncdn.com/377/Midnight-Romance-Bollywood-Hindi-2026-20261019123006-150x150.jpg", "year": "2026", "language": "hindi", "more_info": {"song_count": "5"}}], "total": 1241, "last_page": false}}
"""#

private let saavnPlaylist = #"""
{"id": "1170578779", "title": "Tamil 1990s", "subtitle": "Just Updated", "header_desc": "50 songs with music from artists like Pushpavanam Kuppusamy, Swarnalatha, Vidyasagar, and more.", "type": "playlist", "perma_url": "https://www.jiosaavn.com/featured/tamil-1990s/,H6xc4W4ZimpJ,OEBt5Zbg__", "image": "https://c.saavncdn.com/editorial/charts_Tamil1990s_190250_20240408062124.jpg?bch=1795539603", "list_count": "50", "more_info": {"firstname": "JioSaavn", "song_count": "50"}, "list": [{"id": "bOgiP1I8", "title": "Thottu Thottu", "subtitle": "Pushpavanam Kuppusamy, Pushpavanam Kuppusamy, Swarnalatha, Swarnalatha - Ethirum Puthirum", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/thottu-thottu/EicMWCQBfgs", "image": "https://c.saavncdn.com/962/Ethirum-Puthirum-Tamil-2017-20171229163146-150x150.jpg", "language": "tamil", "year": "2017", "play_count": "6400078", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Vidyasagar", "album_id": "12012346", "album": "Ethirum Puthirum", "label": "Music Master", "label_id": "112527", "origin": "playlist", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/ethirum-puthirum/G9TXnhnX4J0_", "duration": "285", "rights": {"code": "1", "cacheable": "true", "delete_cached_object": "false", "reason": "Pro Only"}, "cache_state": "", "has_lyrics": "true", "has_trivia": true, "starred": "false", "artistMap": {"primary_artists": [{"id": "457525", "name": "Pushpavanam Kuppusamy", "image": "https://c.saavncdn.com/artists/Pushpavanam_Kuppusamy_000_20240918091416_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/pushpavanam-kuppusamy-songs/vCC1TSFbcdI_"}, {"id": "4280343", "name": "Pushpavanam Kuppusamy", "image": "", "perma_url": "https://www.jiosaavn.com/artist/pushpavanam-kuppusamy-songs/uLB6fQdYK8Y_"}]}, "release_date": "2017-10-09", "label_url": "/label/music-master-albums/OF6Ncge98yk_", "vcode": "010911261621114", "vlink": "https://jiotunepreview.jio.com/content/Converted/010911261578262.mp3", "triller_available": false, "request_jiotune_flag": false, "webp": "true", "lyrics_id": ""}}, {"id": "1YccdnS2", "title": "Thamarai Poovukum", "subtitle": "Vidyasagar, Krishna Chandar, Sujatha Mohan, Vairamuthu - Pasumpon", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/thamarai-poovukum/QTEIUhBeZAE", "image": "https://c.saavncdn.com/152/Pasumpon-Original-Motion-Picture-Soundtrack-Tamil-1995-20231026165012-150x150.jpg", "language": "tamil", "year": "2013", "play_count": "15596607", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Vidyasagar", "album_id": "1131524", "album": "Pasumpon", "label": "Magnasound", "label_id": "1543830", "origin": "playlist", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/pasumpon/w8vO9IqrDtY_", "duration": "327", "rights": {"code": "1", "cacheable": "true", "delete_cached_object": "false", "reason": "Pro Only"}, "cache_state": "", "has_lyrics": "false", "has_trivia": "false", "starred": "false", "artistMap": {"primary_artists": [{"id": "455496", "name": "Vidyasagar", "image": "https://c.saavncdn.com/artists/Vidyasagar_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/vidyasagar-songs/j,xkKnlFhBQ_"}, {"id": "672354", "name": "Krishna Chandar", "image": "https://c.saavncdn.com/152/Pasumpon-2013-150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/krishna-chandar-songs/arG6vENAOsI_"}]}, "release_date": "1995-02-09", "label_url": "/label/magnasound-albums/8LI-WIqulsA_", "vcode": "010910140015883", "vlink": "https://jiotunepreview.jio.com/content/Converted/010910140018718.mp3", "triller_available": false, "request_jiotune_flag": false, "webp": "true"}}]}
"""#

private let saavnPlaylistSearch = #"""
{"total": 683, "start": 1, "results": [{"id": "1170578779", "title": "Tamil 1990s", "subtitle": "100 Songs", "type": "playlist", "image": "https://c.saavncdn.com/editorial/charts_Tamil1990s_190250_20240408062124_150x150.jpg", "perma_url": "https://www.jiosaavn.com/featured/tamil-1990s/,H6xc4W4ZimpJ,OEBt5Zbg__", "more_info": {"uid": "phulki_user", "firstname": "JioSaavn", "artist_name": null, "entity_type": "chart", "entity_sub_type": "", "video_available": false, "is_dolby_content": null, "sub_types": null, "images": null, "lastname": "Editor", "song_count": "100", "language": "tamil"}, "explicit_content": "0"}]}
"""#

private let saavnArtistSearch = #"""
{"total": 195, "start": 1, "results": [{"id": "459320", "name": "Arijit Singh", "image": "https://c.saavncdn.com/artists/Arijit_Singh_004_20241118063717_50x50.jpg", "perma_url": "https://www.jiosaavn.com/artist/arijit-singh-songs/LlRWpHzy3Hk_", "type": "artist"}, {"id": "702776", "name": "Pritam & Arijit Singh", "image": "https://www.jiosaavn.com/_i/3.0/artist-default-film.png", "perma_url": "https://www.jiosaavn.com/artist/pritam-arijit-singh-songs/yE1eQoLw,8Q_", "type": "artist"}]}
"""#

private let saavnLaunch = #"""
{"new_trending": [{"id": "81918542", "title": "Rajini The Jailer 2 (Original Motion Picture Soundtrack)", "subtitle": "", "type": "album", "perma_url": "https://www.jiosaavn.com/album/rajini-the-jailer-2-original-motion-picture-soundtrack/J23INAOXAwk_", "image": "https://c.saavncdn.com/633/Rajini-The-Jailer-2-Original-Motion-Picture-Soundtrack-Hindi-2026-20261013080538-150x150.jpg?bch=498779", "year": "", "more_info": {"release_date": "2026-10-13", "song_count": "12", "artistMap": {"primary_artists": [], "featured_artists": [], "artists": [{"id": "455494", "name": "Various Artists", "role": "", "image": "", "type": "artist", "perma_url": "https://www.jiosaavn.com/artist/various-artists-songs/ztKx8IUBme8_"}]}}}, {"id": "BSaNI3Yr", "title": "FA9LA", "subtitle": "Flipperachi - فصلة", "header_desc": "", "type": "song", "perma_url": "https://www.jiosaavn.com/song/fa9la/MjsKfz0DbkE", "image": "https://c.saavncdn.com/598/OR_198588182598-Arabic-2024-20240524121505-150x150.jpg?bch=498779", "language": "arabic", "year": "2024", "play_count": "8384562", "explicit_content": "0", "list_count": "0", "list_type": "", "list": "", "more_info": {"music": "Hussam Assim", "album_id": "54611264", "album": "فصلة", "label": "Outlaw Productions", "label_id": "397966", "origin": "none", "is_dolby_content": false, "320kbps": "true", "encrypted_media_url": "ENCRYPTED", "encrypted_cache_url": "", "encrypted_drm_cache_url": "", "encrypted_drm_media_url": "ENCRYPTED", "album_url": "https://www.jiosaavn.com/album/%d9%81%d8%b5%d9%84%d8%a9/m3VglOSA0eo_", "duration": "105", "rights": {"code": "0", "cacheable": "true"}, "cache_state": "false", "has_lyrics": "false", "has_trivia": "false", "starred": "false", "artistMap": {"primary_artists": [{"id": "2393548", "name": "Flipperachi", "image": "https://c.saavncdn.com/artists/Flipperachi_000_20251212122325_150x150.jpg", "perma_url": "https://www.jiosaavn.com/artist/flipperachi-songs/LnMfdXjMGl0_"}]}, "release_date": "2024-05-30", "label_url": "/label/outlaw-productions-albums/pKJp4RENQb4_", "triller_available": false, "request_jiotune_flag": false, "webp": "true"}, "modules": null}, {"id": "77868843", "title": "Hanuman Ansh (Original Motion Picture Soundtrack)", "subtitle": "", "type": "album", "perma_url": "https://www.jiosaavn.com/album/hanuman-ansh-original-motion-picture-soundtrack/d4V0TjOzdMU_", "image": "https://c.saavncdn.com/058/Hanuman-Ansh-Original-Motion-Picture-Soundtrack-Hindi-2026-20260710211303-150x150.jpg?bch=498779", "year": "", "more_info": {"release_date": "2026-07-11", "song_count": "11", "artistMap": {"primary_artists": [], "featured_artists": [], "artists": [{"id": "5910753", "name": "Sadhu Tiwari", "role": "", "image": "https://c.saavncdn.com/601/OM-Shabd-From-The-Accidental-Prime-Minister--Hindi-2019-20190117133925-150x150.jpg", "type": "artist", "perma_url": "https://www.jiosaavn.com/artist/sadhu-tiwari-songs/Ba4hc1DO4-8_"}, {"id": "7685916", "name": " Rishi Pathak", "role": "", "image": "", "type": "artist", "perma_url": "https://www.jiosaavn.com/artist/-rishi-pathak-songs/xJnAr45PAXg_"}, {"id": "1851741", "name": " Shreyas Dharmadhikari", "role": "", "image": "https://c.saavncdn.com/888/Tere-Bina-feat-NDot--Hindi-2019-20191016123038-150x150.jpg", "type": "artist", "perma_url": "https://www.jiosaavn.com/artist/-shreyas-dharmadhikari-songs/yqxYnTxzwuM_"}, {"id": "19610048", "name": " Suneel Lodhi", "role": "", "image": "", "type": "artist", "perma_url": "https://www.jiosaavn.com/artist/-suneel-lodhi-songs/PYGDsjBKaUc_"}]}}}], "top_playlists": [{"id": "932189657", "title": "Best Of Dance - Hindi", "subtitle": "Just Updated", "type": "playlist", "perma_url": "https://www.jiosaavn.com/featured/best-of-dance-hindi/qVvfieICUY5ieSJqt9HmOQ__", "image": "https://c.saavncdn.com/editorial/BestOfDanceHindi_20261021051947.jpg", "more_info": {"song_count": "50", "firstname": "JioSaavn", "follower_count": "161286", "last_updated": "1795573994", "uid": "phulki_user"}}], "modules": {"new_trending": {"title": "Trending Now"}, "top_playlists": {"title": "Top Playlists"}}}
"""#

private let itunesSongs = #"""
{"resultCount": 2, "results": [{"wrapperType": "track", "kind": "song", "artistId": 3296287, "collectionId": 6781024026, "trackId": 6781024437, "artistName": "Queen", "collectionName": "A Night At The Opera (Deluxe Edition)", "trackName": "Bohemian Rhapsody", "artistViewUrl": "https://music.apple.com/us/artist/queen/3296287?uo=4", "collectionViewUrl": "https://music.apple.com/us/album/bohemian-rhapsody/6781024026?i=6781024437&uo=4", "trackViewUrl": "https://music.apple.com/us/album/bohemian-rhapsody/6781024026?i=6781024437&uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/8b/0a/ea/8b0aea60-6f4a-195b-5958-cdf459c2333b/602527644271.jpg/100x100bb.jpg", "releaseDate": "1975-10-31T12:00:00Z", "collectionExplicitness": "notExplicit", "trackExplicitness": "notExplicit", "discNumber": 1, "trackCount": 12, "trackNumber": 11, "trackTimeMillis": 354320, "country": "USA", "primaryGenreName": "Rock"}, {"wrapperType": "track", "kind": "song", "artistId": 80456331, "collectionId": 1125281254, "trackId": 1125281672, "artistName": "Panic! At the Disco", "collectionName": "Suicide Squad: The Album", "trackName": "Bohemian Rhapsody", "collectionArtistId": 36270, "collectionArtistName": "Various Artists", "artistViewUrl": "https://music.apple.com/us/artist/panic-at-the-disco/80456331?uo=4", "collectionViewUrl": "https://music.apple.com/us/album/bohemian-rhapsody/1125281254?i=1125281672&uo=4", "trackViewUrl": "https://music.apple.com/us/album/bohemian-rhapsody/1125281254?i=1125281672&uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/2f/76/c0/2f76c0c7-5aaf-eb97-2002-f40c9ecde722/075679910486.jpg/100x100bb.jpg", "releaseDate": "2016-08-04T07:00:00Z", "collectionExplicitness": "explicit", "trackExplicitness": "notExplicit", "discNumber": 1, "trackCount": 14, "trackNumber": 11, "trackTimeMillis": 361800, "country": "USA", "primaryGenreName": "Alternative"}]}
"""#

private let itunesAlbumLookup = #"""
{"resultCount": 4, "results": [{"wrapperType": "collection", "collectionType": "Album", "artistId": 3296287, "collectionId": 6781024026, "amgArtistId": 5205, "artistName": "Queen", "collectionName": "A Night At The Opera (Deluxe Edition)", "artistViewUrl": "https://music.apple.com/us/artist/queen/3296287?uo=4", "collectionViewUrl": "https://music.apple.com/us/album/a-night-at-the-opera-deluxe-edition/6781024026?uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/8b/0a/ea/8b0aea60-6f4a-195b-5958-cdf459c2333b/602527644271.jpg/100x100bb.jpg", "collectionExplicitness": "notExplicit", "trackCount": 18, "copyright": "℗ 1975 Queen Productions Ltd. (ROW)/Hollywood Records, Inc. (USA & Can)", "country": "USA", "releaseDate": "1975-11-21T08:00:00Z", "primaryGenreName": "Rock"}, {"wrapperType": "track", "kind": "song", "artistId": 3296287, "collectionId": 6781024026, "trackId": 6781024028, "artistName": "Queen", "collectionName": "A Night At The Opera (Deluxe Edition)", "trackName": "Death On Two Legs (Dedicated To...)", "artistViewUrl": "https://music.apple.com/us/artist/queen/3296287?uo=4", "collectionViewUrl": "https://music.apple.com/us/album/death-on-two-legs-dedicated-to/6781024026?i=6781024028&uo=4", "trackViewUrl": "https://music.apple.com/us/album/death-on-two-legs-dedicated-to/6781024026?i=6781024028&uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/8b/0a/ea/8b0aea60-6f4a-195b-5958-cdf459c2333b/602527644271.jpg/100x100bb.jpg", "releaseDate": "1975-11-21T12:00:00Z", "collectionExplicitness": "notExplicit", "trackExplicitness": "notExplicit", "discNumber": 1, "trackCount": 12, "trackNumber": 1, "trackTimeMillis": 223094, "country": "USA", "primaryGenreName": "Rock"}, {"wrapperType": "track", "kind": "song", "artistId": 3296287, "collectionId": 6781024026, "trackId": 6781024424, "artistName": "Queen", "collectionName": "A Night At The Opera (Deluxe Edition)", "trackName": "Lazing On A Sunday Afternoon", "artistViewUrl": "https://music.apple.com/us/artist/queen/3296287?uo=4", "collectionViewUrl": "https://music.apple.com/us/album/lazing-on-a-sunday-afternoon/6781024026?i=6781024424&uo=4", "trackViewUrl": "https://music.apple.com/us/album/lazing-on-a-sunday-afternoon/6781024026?i=6781024424&uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/8b/0a/ea/8b0aea60-6f4a-195b-5958-cdf459c2333b/602527644271.jpg/100x100bb.jpg", "releaseDate": "1975-11-21T12:00:00Z", "collectionExplicitness": "notExplicit", "trackExplicitness": "notExplicit", "discNumber": 1, "trackCount": 12, "trackNumber": 2, "trackTimeMillis": 67226, "country": "USA", "primaryGenreName": "Rock"}, {"wrapperType": "track", "kind": "song", "artistId": 3296287, "collectionId": 6781024026, "trackId": 6781024426, "artistName": "Queen", "collectionName": "A Night At The Opera (Deluxe Edition)", "trackName": "I'm In Love With My Car", "artistViewUrl": "https://music.apple.com/us/artist/queen/3296287?uo=4", "collectionViewUrl": "https://music.apple.com/us/album/im-in-love-with-my-car/6781024026?i=6781024426&uo=4", "trackViewUrl": "https://music.apple.com/us/album/im-in-love-with-my-car/6781024026?i=6781024426&uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/8b/0a/ea/8b0aea60-6f4a-195b-5958-cdf459c2333b/602527644271.jpg/100x100bb.jpg", "releaseDate": "1975-11-21T12:00:00Z", "collectionExplicitness": "notExplicit", "trackExplicitness": "notExplicit", "discNumber": 1, "trackCount": 12, "trackNumber": 3, "trackTimeMillis": 185067, "country": "USA", "primaryGenreName": "Rock"}]}
"""#

private let itunesArtistAlbums = #"""
{"resultCount": 3, "results": [{"wrapperType": "artist", "artistType": "Artist", "artistName": "Queen", "artistLinkUrl": "https://music.apple.com/us/artist/queen/3296287?uo=4", "artistId": 3296287, "amgArtistId": 5205, "primaryGenreName": "Rock", "primaryGenreId": 21}, {"wrapperType": "collection", "collectionType": "Album", "artistId": 3296287, "collectionId": 1528212071, "amgArtistId": 5205, "artistName": "Queen & Adam Lambert", "collectionName": "Live Around the World (Deluxe)", "artistViewUrl": "https://music.apple.com/us/artist/queen/3296287?uo=4", "collectionViewUrl": "https://music.apple.com/us/album/live-around-the-world-deluxe/1528212071?uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music124/v4/89/9a/ad/899aad1a-c520-ac9f-178a-c66ea350c046/20UMGIM70174.rgb.jpg/100x100bb.jpg", "collectionExplicitness": "explicit", "trackCount": 20, "copyright": "℗ 2020 Miracle Recordings Ltd. under exclusive license to Hollywood Records, Inc.", "country": "USA", "releaseDate": "2020-10-02T07:00:00Z", "primaryGenreName": "Rock"}, {"wrapperType": "collection", "collectionType": "Album", "artistId": 3296287, "collectionId": 1410128554, "amgArtistId": 5205, "artistName": "Queen", "collectionName": "Flash Gordon", "artistViewUrl": "https://music.apple.com/us/artist/queen/3296287?uo=4", "collectionViewUrl": "https://music.apple.com/us/album/flash-gordon/1410128554?uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/dd/bb/58/ddbb5893-9d3d-bdc2-761d-b037ffe1e608/00720616120328.rgb.jpg/100x100bb.jpg", "collectionExplicitness": "notExplicit", "trackCount": 19, "copyright": "℗ 1991 Hollywood Records, Inc.", "country": "USA", "releaseDate": "1980-12-08T00:00:00Z", "primaryGenreName": "Rock"}]}
"""#

private let itunesArtists = #"""
{"resultCount": 1, "results": [{"wrapperType": "artist", "artistType": "Artist", "artistName": "Queen", "artistLinkUrl": "https://music.apple.com/us/artist/queen/3296287?uo=4", "artistId": 3296287, "amgArtistId": 5205, "primaryGenreName": "Rock", "primaryGenreId": 21}]}
"""#

private let itunesAlbums = #"""
{"resultCount": 1, "results": [{"wrapperType": "collection", "collectionType": "Album", "artistId": 3296287, "collectionId": 6781027361, "amgArtistId": 5205, "artistName": "Queen", "collectionName": "Bohemian Rhapsody (The Original Soundtrack)", "artistViewUrl": "https://music.apple.com/us/artist/queen/3296287?uo=4", "collectionViewUrl": "https://music.apple.com/us/album/bohemian-rhapsody-the-original-soundtrack/6781027361?uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/62/2e/97/622e97c4-d620-2ae1-2a47-a32e16a01492/602567988847.jpg/100x100bb.jpg", "collectionExplicitness": "notExplicit", "trackCount": 22, "copyright": "℗ 2018 Queen Productions Ltd. (ROW)/Hollywood Records, Inc. (USA & Can)", "country": "USA", "releaseDate": "2018-10-19T07:00:00Z", "primaryGenreName": "Rock"}]}
"""#

private let itunesChart = #"""
{"feed": {"title": "Top Songs", "country": "in", "results": [{"artistName": "Karan Aujla & MXRCI", "id": "6814002647", "name": "Ashke", "releaseDate": "2026-09-25", "kind": "songs", "artistId": "914892130", "artistUrl": "https://music.apple.com/in/artist/karan-aujla/914892130", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/f7/6d/78/f76d78c5-cc9c-f2d6-8603-ba690eaa5c7d/5064089826918_cover.jpg/100x100bb.jpg", "url": "https://music.apple.com/in/album/ashke/6814002539?i=6814002647"}, {"artistName": "Sai Abhyankkar, Tippu & Arun Srinivasan", "id": "6824473553", "name": "Veezha Veera (From \"OM Chapter 1: Udhiram  - The Blood Wood\") [Tamil]", "releaseDate": "2026-10-19", "kind": "songs", "artistId": "1652280551", "artistUrl": "https://music.apple.com/in/artist/sai-abhyankkar/1652280551", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/f1/16/40/f11640a5-a80c-d676-17f3-15930c99d44a/1200220338696.jpg/100x100bb.jpg", "url": "https://music.apple.com/in/album/veezha-veera-from-om-chapter-1-udhiram-the-blood-wood-tamil/6824473544?i=6824473553"}, {"artistName": "Rito Riba & Siddhant Kaushal", "id": "6819312875", "name": "Dilruba Dilnasheen", "releaseDate": "2026-10-16", "kind": "songs", "artistId": "1646959884", "artistUrl": "https://music.apple.com/in/artist/rito-riba/1646959884", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/a5/61/9c/a5619ce1-804e-f099-26d0-43df477ff378/823375513346_Cover.jpg/100x100bb.jpg", "url": "https://music.apple.com/in/album/dilruba-dilnasheen/6819312748?i=6819312875"}]}}
"""#

private let itunesChartLookup = #"""
{"resultCount": 3, "results": [{"wrapperType": "track", "kind": "song", "artistId": 914892130, "collectionId": 6814002539, "trackId": 6814002647, "artistName": "Karan Aujla & MXRCI", "collectionName": "AUJLA SZN 1 - EP", "trackName": "Ashke", "collectionArtistName": "Karan Aujla", "artistViewUrl": "https://music.apple.com/in/artist/karan-aujla/914892130?uo=4", "collectionViewUrl": "https://music.apple.com/in/album/ashke/6814002539?i=6814002647&uo=4", "trackViewUrl": "https://music.apple.com/in/album/ashke/6814002539?i=6814002647&uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/f7/6d/78/f76d78c5-cc9c-f2d6-8603-ba690eaa5c7d/5064089826918_cover.jpg/100x100bb.jpg", "releaseDate": "2026-09-25T12:00:00Z", "collectionExplicitness": "notExplicit", "trackExplicitness": "notExplicit", "discNumber": 1, "trackCount": 5, "trackNumber": 1, "trackTimeMillis": 217625, "country": "IND", "primaryGenreName": "Hip-Hop/Rap"}, {"wrapperType": "track", "kind": "song", "artistId": 1652280551, "collectionId": 6824473544, "trackId": 6824473553, "artistName": "Sai Abhyankkar, Tippu & Arun Srinivasan", "collectionName": "Veezha Veera (From \"OM Chapter 1: Udhiram  - The Blood Wood\") [Tamil] - Single", "trackName": "Veezha Veera (From \"OM Chapter 1: Udhiram  - The Blood Wood\") [Tamil]", "artistViewUrl": "https://music.apple.com/in/artist/sai-abhyankkar/1652280551?uo=4", "collectionViewUrl": "https://music.apple.com/in/album/veezha-veera-from-om-chapter-1-udhiram-the-blood-wood-tamil/6824473544?i=6824473553&uo=4", "trackViewUrl": "https://music.apple.com/in/album/veezha-veera-from-om-chapter-1-udhiram-the-blood-wood-tamil/6824473544?i=6824473553&uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/f1/16/40/f11640a5-a80c-d676-17f3-15930c99d44a/1200220338696.jpg/100x100bb.jpg", "releaseDate": "2026-10-19T12:00:00Z", "collectionExplicitness": "notExplicit", "trackExplicitness": "notExplicit", "discNumber": 1, "trackCount": 1, "trackNumber": 1, "trackTimeMillis": 236081, "country": "IND", "primaryGenreName": "Tamil"}, {"wrapperType": "track", "kind": "song", "artistId": 1646959884, "collectionId": 6819312748, "trackId": 6819312875, "artistName": "Rito Riba & Siddhant Kaushal", "collectionName": "Dilfek - EP", "trackName": "Dilruba Dilnasheen", "collectionArtistName": "Rito Riba", "artistViewUrl": "https://music.apple.com/in/artist/rito-riba/1646959884?uo=4", "collectionViewUrl": "https://music.apple.com/in/album/dilruba-dilnasheen/6819312748?i=6819312875&uo=4", "trackViewUrl": "https://music.apple.com/in/album/dilruba-dilnasheen/6819312748?i=6819312875&uo=4", "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/a5/61/9c/a5619ce1-804e-f099-26d0-43df477ff378/823375513346_Cover.jpg/100x100bb.jpg", "releaseDate": "2026-10-16T12:00:00Z", "collectionExplicitness": "notExplicit", "trackExplicitness": "notExplicit", "discNumber": 1, "trackCount": 5, "trackNumber": 3, "trackTimeMillis": 173138, "country": "IND", "primaryGenreName": "Worldwide"}]}
"""#


// MARK: helpers

private final class ContractStub: MusicHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    var requests: [URLRequest] { lock.withLock { seen } }
    func count(host: String) -> Int { requests.filter { $0.url?.host == host }.count }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { seen.append(request) }
        let (code, body) = handler(request)
        let resp = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: code, httpVersion: nil, headerFields: nil)
        return (Data(body.utf8), resp ?? HTTPURLResponse())
    }
}

private func http(_ s: ContractStub) -> MusicHTTP { MusicHTTP(transport: s) }
private func query(_ r: URLRequest?, _ name: String) -> String? {
    r?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
}
private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

// MARK: Audius

@Suite struct ProviderContractAudius {
    private func stub(_ routes: [String: String] = [:], status: Int = 200) -> ContractStub {
        ContractStub { r in
            if r.url?.host == "api.audius.co", r.url?.path == "" || r.url?.path == "/" { return (200, #"{"data":["https://api.audius.co"]}"#) }
            let path = r.url?.path ?? ""
            for (k, v) in routes where path.hasSuffix(k) { return (status, v) }
            return (404, "")
        }
    }

    @Test func searchMapsIsrcThumbnailsAndStream() async throws {
        let s = stub(["/v1/tracks/search": audiusTracks])
        let page = try await AudiusProvider(http: http(s)).searchTracks("Bohemian Rhapsody", page: .offset(offset: 0, limit: 2))
        let t = try #require(page.items.first)
        #expect(t.providerID == "audius" && t.isrc != nil && t.durationMs > 0 && !t.explicit)
        #expect(t.thumbnails.map(\.width) == t.thumbnails.map(\.width).sorted() && !t.thumbnails.isEmpty)
        #expect(!t.thumbnails.contains { $0.url.isEmpty })
        let st = try #require(t.directStreams?.first)
        #expect(st.url == "https://api.audius.co/v1/tracks/\(t.id)/stream?app_name=StreamSetu" && st.container == "mp3" && st.bitrate == 320)
        #expect(page.next == .offset(offset: 2, limit: 2))
        let req = try #require(s.requests.last)
        #expect(query(req, "query") == "Bohemian Rhapsody" && query(req, "app_name") == "StreamSetu" && query(req, "limit") == "2" && query(req, "offset") == "0")
        #expect(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("StreamSetu-Music") == true)
    }

    @Test func gatedDeletedAndUnstreamableTracksClaimNoStream() throws {
        let base: [String: Any] = ["id": "a", "title": "T", "user": ["id": "u", "name": "N"]]
        func with(_ k: String, _ v: Any) -> [String: Any] { base.merging([k: v]) { $1 } }
        #expect(AudiusProvider.mapTrack(base, host: "https://h")?.directStreams != nil)
        #expect(AudiusProvider.mapTrack(with("is_stream_gated", true), host: "https://h")?.directStreams == nil)
        #expect(AudiusProvider.mapTrack(with("is_delete", true), host: "https://h")?.directStreams == nil)
        #expect(AudiusProvider.mapTrack(with("is_streamable", false), host: "https://h")?.directStreams == nil)
        #expect(AudiusProvider.mapTrack(with("access", ["stream": false, "download": false]), host: "https://h")?.directStreams == nil)
    }

    @Test func explicitFlagComesFromParentalWarning() {
        let d: [String: Any] = ["id": "a", "title": "T", "parental_warning_type": "explicit", "user": ["id": "u", "name": "N"]]
        #expect(AudiusProvider.mapTrack(d, host: "https://h")?.explicit == true)
    }

    @Test func directoryFailureFallsBackToTheMainHost() async throws {
        let s = ContractStub { r in
            if r.url?.path == "/v1/tracks/search" { return (200, audiusTracks) }
            return (500, "")
        }
        let page = try await AudiusProvider(http: http(s)).searchTracks("x", page: nil)
        #expect(!page.items.isEmpty)
        #expect(s.requests.last?.url?.host == "api.audius.co")
    }

    @Test func unknownIdIsNotFoundAndDoesNotCostAHost() async throws {
        let s = ContractStub { r in
            if r.url?.path == "/" || r.url?.path == "" { return (200, #"{"data":["https://api.audius.co"]}"#) }
            return (400, #"{"code":400,"error":"invalid trackId"}"#)
        }
        let p = AudiusProvider(http: http(s))
        await #expect(throws: MusicError.notFound) { try await p.track(id: "zzzzzzzz") }
        await #expect(throws: MusicError.notFound) { try await p.track(id: "yyyyyyyy") }
        #expect(s.requests.filter { $0.url?.path == "/" || $0.url?.path == "" }.count == 1)
    }

    @Test func serverErrorFailsOverAndForbiddenIsNotASignIn() async throws {
        let s = ContractStub { r in
            switch r.url?.host {
            case "api.audius.co": return (200, #"{"data":["https://bad.example","https://good.example"]}"#)
            case "bad.example": return (403, "")
            default: return (200, audiusUser)
            }
        }
        let a = try await AudiusProvider(http: http(s)).artist(id: "mvZrA")
        #expect(a.name.isEmpty == false && s.requests.last?.url?.host == "good.example")

        let denied = ContractStub { r in r.url?.host == "api.audius.co" && r.url?.path == "/" ? (200, #"{"data":["https://only.example"]}"#) : (403, "") }
        do { _ = try await AudiusProvider(http: http(denied)).artist(id: "x"); Issue.record("expected an error") } catch let e as MusicError {
            if case .notSignedIn = e { Issue.record("403 must not read as a sign-in request") }
        }
    }

    @Test func replyWithoutDataIsAnErrorNotAnEmptyList() async throws {
        let s = stub(["/v1/tracks/search": #"{"unexpected":true}"#])
        await #expect(throws: MusicError.network("unexpected reply")) { try await AudiusProvider(http: http(s)).searchTracks("x", page: nil) }
    }

    @Test func albumsPlaylistsAndArtistsMap() async throws {
        let s = stub(["/v1/search/full": audiusAlbums, "/v1/playlists/search": audiusPlaylist, "/v1/users/mvZrA": audiusUser])
        let p = AudiusProvider(http: http(s))
        let albums = try await p.searchAlbums("odesza", page: nil)
        let a = try #require(albums.items.first)
        #expect(a.albumType == "Album" && a.releaseDate?.count == 10 && a.totalTracks != nil && !a.artists[0].name.isEmpty)
        #expect(query(s.requests.last, "kind") == "albums")
        let pl = try #require(try await p.searchPlaylists("queen", page: nil).items.first)
        #expect(!pl.name.isEmpty && pl.trackCount != nil)
        let artist = try await p.artist(id: "mvZrA")
        #expect(artist.followers != nil && artist.bio != nil)
    }

    @Test func streamsForSourceUseTheCurrentHost() async throws {
        let s = stub()
        let src = MusicAudioSource(id: "w7Bap", providerID: "audius", title: "T", artist: nil, album: nil, durationMs: nil, externalURL: nil, confidence: 1)
        let streams = try await AudiusProvider(http: http(s)).streams(for: src)
        #expect(streams.first?.url == "https://api.audius.co/v1/tracks/w7Bap/stream?app_name=StreamSetu")
        #expect(streams.first?.url.hasPrefix("https://") == true)
    }

    @Test func weakTitleMatchesAreNotOfferedAsAudio() async throws {
        let rows = #"{"data":[{"id":"1","title":"Something Else Entirely","duration":200,"user":{"id":"u","name":"Other"}},{"id":"2","title":"Bohemian Rhapsody","duration":355,"user":{"id":"u2","name":"Queen Tribute"}}]}"#
        let s = stub(["/v1/tracks/search": rows])
        let want = MusicTrack(id: "x", providerID: "itunes", title: "Bohemian Rhapsody", durationMs: 354_000, artists: [MusicArtistRef(id: "", name: "Queen")])
        let found = try await AudiusProvider(http: http(s)).sources(for: want)
        #expect(found.map(\.id) == ["2"])
    }

    @Test func featuredHasSectionsAndFailsLoudlyWhenEmpty() async throws {
        let s = stub(["/v1/tracks/trending": audiusTracks])
        let sections = try await AudiusProvider(http: http(s)).featured()
        #expect(sections.first?.id == "audius-trending")
        let bad = ContractStub { r in r.url?.path == "/" ? (200, #"{"data":["https://api.audius.co"]}"#) : (500, "") }
        await #expect(throws: MusicError.self) { try await AudiusProvider(http: http(bad)).featured() }
    }
}

// MARK: JioSaavn

@Suite struct ProviderContractJioSaavn {
    private func stub(_ routes: [String: String], status: Int = 200) -> ContractStub {
        ContractStub { r in
            let call = query(r, "__call") ?? ""
            return (status, routes[call] ?? #"{"status":"failure","msg":"something went wrong"}"#)
        }
    }

    @Test func searchMapsMetadataAndNeverExposesAudio() async throws {
        let s = stub(["search.getResults": saavnSearch])
        let page = try await JioSaavnProvider(http: http(s)).searchTracks("Kaavaalaa", page: .page(1, size: 2))
        let t = try #require(page.items.first)
        #expect(t.title == "Kaavaalaa" && t.durationMs == 190_000 && t.album?.title == "Jailer" && t.popularity != nil)
        #expect(t.artists.count == 2 && !t.artists.contains { $0.name.hasPrefix(" ") })
        #expect(t.thumbnails.map(\.width) == [150, 500])
        #expect(t.directStreams == nil, "encrypted-only tracks must be metadata-only")
        #expect(page.items.allSatisfy { $0.directStreams == nil })
        let second = try #require(page.items.dropFirst().first)
        #expect(second.title.contains("\"Jailer\"") && !second.title.contains("&quot;"))
        let req = try #require(s.requests.last)
        #expect(query(req, "__call") == "search.getResults" && query(req, "ctx") == "web6dot0" && query(req, "api_version") == "4" && query(req, "n") == "2" && query(req, "p") == "1")
        #expect(page.next == .page(2, size: 2))
    }

    @Test func encryptedAndClipFieldsAreNeverTurnedIntoStreams() throws {
        // The fixture rows carry encrypted_media_url, encrypted_drm_media_url and a caller-tune preview address (vlink, a clip under 20 s).
        let raw = try object(saavnSong)
        let song = try #require((raw["songs"] as? [[String: Any]])?.first)
        let more = try #require(song["more_info"] as? [String: Any])
        #expect(more["encrypted_media_url"] != nil && (more["vlink"] as? String)?.contains("jiotunepreview") == true)
        let t = try #require(JioSaavnProvider.mapSong(song))
        #expect(t.directStreams == nil)
        #expect(JioSaavnProvider.streams(media: more["vlink"] as? String).isEmpty)
        #expect(JioSaavnProvider.streams(media: "https://preview.saavncdn.com/123/abc_96_p.mp4").isEmpty)
        #expect(JioSaavnProvider.streams(media: "https://evil.example/a_320.mp4").isEmpty)
        #expect(JioSaavnProvider.streams(media: "ENCRYPTED").isEmpty)
    }

    @Test func aPlainFullLengthAddressIsUsedWhenTheServicePublishesOne() {
        let s = JioSaavnProvider.streams(media: "http://aac.saavncdn.com/123/abc_320.mp4")
        #expect(s.count == 1 && s[0].url == "https://aac.saavncdn.com/123/abc_320.mp4" && s[0].bitrate == 320)
    }

    @Test func tracksWithoutAStreamAreNotAudioSourcesAndMakeNoRequest() async throws {
        let s = stub([:])
        let p = JioSaavnProvider(http: http(s))
        let t = MusicTrack(id: "a", providerID: "jiosaavn", title: "Tum Hi Ho", durationMs: 262_000, artists: [MusicArtistRef(id: "", name: "Arijit")])
        #expect(try await p.sources(for: t).isEmpty)
        let foreign = MusicTrack(id: "b", providerID: "itunes", title: "Tum Hi Ho", durationMs: 262_000, artists: [MusicArtistRef(id: "", name: "Arijit")])
        #expect(try await p.sources(for: foreign).isEmpty)
        #expect(s.requests.isEmpty)
        #expect(!p.capabilities.contains(.audio))
        let src = MusicAudioSource(id: "a", providerID: "jiosaavn", title: "Tum Hi Ho", artist: nil, album: nil, durationMs: nil, externalURL: nil, confidence: 1)
        await #expect(throws: MusicError.noPlayableSource("Tum Hi Ho")) { try await p.streams(for: src) }
    }

    @Test func songDetailAlbumAndPlaylistMapping() async throws {
        let s = stub(["song.getDetails": saavnSong, "content.getAlbumDetails": saavnAlbum, "playlist.getDetails": saavnPlaylist])
        let p = JioSaavnProvider(http: http(s))
        let t = try await p.track(id: "aRZbUYD7")
        #expect(t.id == "aRZbUYD7" && t.durationMs > 0 && t.album?.id != nil)
        let a = try await p.album(id: "1139549")
        #expect(a.title == "Aashiqui 2" && a.releaseDate == "2013" && a.totalTracks == 10 && a.artists.count == 3 && !a.artists.contains { $0.name.hasPrefix(" ") })
        let tracks = try await p.albumTracks(id: "1139549", page: .page(1, size: 3))
        #expect(tracks.items.count == 3 && tracks.totalCount == 10 && tracks.next == .page(2, size: 3))
        #expect(query(s.requests.last, "p") == "1" && query(s.requests.last, "n") == "3")
        let pl = try await p.playlist(id: "1170578779")
        #expect(pl.trackCount == 50 && pl.owner == "JioSaavn")
        let plTracks = try await p.playlistTracks(id: "1170578779", page: .page(2, size: 2))
        #expect(plTracks.items.count == 2 && query(s.requests.last, "p") == "2")
    }

    @Test func unknownAlbumSampleObjectIsNotFound() async throws {
        let sample = #"{"id":"","title":"","type":"album","list_count":"1","list":[{"id":"dsf7m88e","title":"This is a sample trailer - testing"}]}"#
        let p = JioSaavnProvider(http: http(stub(["content.getAlbumDetails": sample])))
        await #expect(throws: MusicError.notFound) { try await p.album(id: "0") }
        await #expect(throws: MusicError.notFound) { try await p.albumTracks(id: "0", page: nil) }
    }

    @Test func failureBodiesAndHttpErrorsAreClearErrors() async throws {
        await #expect(throws: MusicError.notFound) { try await JioSaavnProvider(http: http(stub([:]))).track(id: "zzzz") }
        let err = stub(["search.getResults": #"{"error":{"code":"INPUT_INVALID","msg":"call operation is not supported"}}"#])
        await #expect(throws: MusicError.network("call operation is not supported")) { try await JioSaavnProvider(http: http(err)).searchTracks("x", page: nil) }
        let html = stub(["search.getResults": "<html>blocked</html>"])
        await #expect(throws: MusicError.network("unexpected reply")) { try await JioSaavnProvider(http: http(html)).searchTracks("x", page: nil) }
        let forbidden = ContractStub { _ in (403, "") }
        do { _ = try await JioSaavnProvider(http: http(forbidden)).searchTracks("x", page: nil); Issue.record("expected an error") } catch let e as MusicError {
            if case .notSignedIn = e { Issue.record("403 must not read as a sign-in request") }
        }
        let limited = ContractStub { _ in (429, "") }
        do { _ = try await JioSaavnProvider(http: http(limited)).searchTracks("x", page: nil); Issue.record("expected an error") } catch let e as MusicError {
            if case .rateLimited = e {} else { Issue.record("429 must read as rate limited, got \(e)") }
        }
    }

    @Test func serverErrorIsRetriedOnce() async throws {
        let calls = LockedCounter()
        let s = ContractStub { _ in calls.next() == 1 ? (503, "") : (200, saavnSearch) }
        let page = try await JioSaavnProvider(http: http(s)).searchTracks("x", page: nil)
        #expect(page.items.count == 2 && s.requests.count == 2)
    }

    @Test func searchSizeIsCappedAtWhatTheServiceServes() async throws {
        let s = stub(["search.getResults": saavnSearch])
        _ = try await JioSaavnProvider(http: http(s)).searchTracks("x", page: .page(1, size: 100))
        #expect(query(s.requests.last, "n") == "40")
    }

    @Test func artistPageSearchAndAlbumPaging() async throws {
        let s = stub(["artist.getArtistPageDetails": saavnArtist, "search.getArtistResults": saavnArtistSearch, "artist.getArtistMoreAlbum": saavnArtistAlbums,
                      "search.getPlaylistResults": saavnPlaylistSearch])
        let p = JioSaavnProvider(http: http(s))
        let a = try await p.artist(id: "459320")
        #expect(a.name == "Arijit Singh" && a.followers == 109_923_760 && a.bio == "Indian playback singer.")
        #expect(try await p.artistTopTracks(id: "459320").count == 2)
        let found = try await p.searchArtists("arijit", page: nil)
        #expect(found.items.first?.thumbnails.first?.url.contains("150x150") == true)
        let albums = try await p.artistAlbums(id: "459320", page: .page(1, size: 10))
        #expect(albums.items.count == 2 && albums.totalCount == 1241 && albums.next == .page(2, size: 10))
        #expect(query(s.requests.last, "page") == "0")
        let pls = try await p.searchPlaylists("tamil", page: nil)
        #expect(pls.items.first?.trackCount == 100)
    }

    @Test func homeModulesKeepTheServiceTitles() async throws {
        let s = stub(["webapi.getLaunchData": saavnLaunch])
        let sections = try await JioSaavnProvider(http: http(s)).featured()
        #expect(sections.map(\.title).contains("Trending Now") && sections.map(\.title).contains("Top Playlists"))
        #expect(sections.allSatisfy { !$0.items.isEmpty })
        await #expect(throws: MusicError.self) { try await JioSaavnProvider(http: http(stub(["webapi.getLaunchData": "{}"]))).featured() }
    }

    @Test func entitiesAreDecoded() {
        #expect(JioSaavnProvider.clean("Rock &amp; Roll &quot;Hits&quot; &#039;99") == "Rock & Roll \"Hits\" '99")
        #expect(JioSaavnProvider.clean("plain") == "plain")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

// MARK: Apple catalogue

@Suite struct ProviderContractITunes {
    private func stub(_ routes: [String: String], status: Int = 200) -> ContractStub {
        ContractStub { r in
            let path = r.url?.path ?? ""
            for (k, v) in routes where path.hasSuffix(k) || (r.url?.host ?? "").contains(k) { return (status, v) }
            return (404, "")
        }
    }
    private func provider(_ s: ContractStub, country: String? = nil) -> ITunesProvider { ITunesProvider(http: http(s), country: { country }) }

    @Test func songsMapWithoutAnyPlayableAudio() async throws {
        let s = stub(["/search": itunesSongs])
        let page = try await provider(s).searchTracks("Bohemian Rhapsody", page: .offset(offset: 0, limit: 2))
        let t = try #require(page.items.first)
        #expect(t.providerID == "itunes" && t.durationMs > 0 && t.album?.id != nil && !t.explicit)
        #expect(t.directStreams == nil, "previews must not be offered as audio")
        #expect(t.thumbnails.last?.url.contains("600x600bb") == true)
        #expect(!s.requests.contains { $0.url?.absoluteString.contains("previewUrl") == true })
    }

    @Test func storefrontIsSentOnlyWhenValidAndFallsBackWhenEmpty() async throws {
        let s = stub(["/search": itunesSongs])
        _ = try await provider(s, country: "IN").searchTracks("x", page: nil)
        #expect(query(s.requests.first, "country") == "in")
        let none = stub(["/search": itunesSongs])
        _ = try await provider(none, country: "xx1").searchTracks("x", page: nil)
        #expect(query(none.requests.first, "country") == nil)
        let empty = ContractStub { r in query(r, "country") != nil ? (200, #"{"resultCount":0,"results":[]}"#) : (200, itunesSongs) }
        let page = try await provider(empty, country: "IN").searchTracks("x", page: nil)
        #expect(!page.items.isEmpty && empty.requests.count == 2 && query(empty.requests.last, "country") == nil)
        let rejected = ContractStub { r in query(r, "country") != nil ? (400, "") : (200, itunesSongs) }
        #expect(try await provider(rejected, country: "ZZ").searchTracks("x", page: nil).items.isEmpty == false)
    }

    @Test func pagingIsCutFromOneLargerReplyBecauseOffsetIsIgnored() async throws {
        let rows = (0..<10).map { #"{"wrapperType":"track","kind":"song","trackId":\#($0 + 1),"trackName":"S\#($0)","artistName":"A"}"# }
        let s = ContractStub { r in
            let limit = Int(query(r, "limit") ?? "") ?? 0
            return (200, #"{"resultCount":\#(limit),"results":["# + rows.prefix(limit).joined(separator: ",") + "]}")
        }
        let p = provider(s)
        let page2 = try await p.searchTracks("love", page: .offset(offset: 5, limit: 5))
        #expect(page2.items.map(\.id) == ["6", "7", "8", "9", "10"])
        #expect(query(s.requests.last, "limit") == "10" && query(s.requests.last, "offset") == nil)
        #expect(page2.next == .offset(offset: 10, limit: 5))
        let capped = try await p.searchTracks("love", page: .offset(offset: 200, limit: 20))
        #expect(capped.items.isEmpty && capped.next == nil && s.requests.count == 1)
    }

    @Test func lastWindowHasNoNextPage() async throws {
        let s = stub(["/search": #"{"resultCount":3,"results":[{"wrapperType":"track","kind":"song","trackId":1,"trackName":"A"}]}"#])
        #expect(try await provider(s).searchTracks("x", page: .offset(offset: 190, limit: 20)).next == nil)
        #expect(query(s.requests.last, "limit") == "200")
    }

    @Test func albumTracksSortAndAlbumTypes() async throws {
        let s = stub(["/lookup": itunesAlbumLookup])
        let p = provider(s)
        let tracks = try await p.albumTracks(id: "6781024026", page: nil)
        #expect(!tracks.items.isEmpty && tracks.items.map { $0.trackNumber ?? 0 } == tracks.items.map { $0.trackNumber ?? 0 }.sorted())
        #expect(query(s.requests.first, "entity") == "song" && query(s.requests.first, "id") == "6781024026")
        let album = try await p.album(id: "6781024026")
        #expect(album.albumType == "Album" && album.releaseDate?.count == 10)
        let single = try #require(ITunesProvider.mapAlbum(["wrapperType": "collection", "collectionId": 1, "collectionName": "Song - Single"]))
        #expect(single.albumType == "Single")
    }

    @Test func artistAlbumsNewestFirst() async throws {
        let s = stub(["/lookup": itunesArtistAlbums])
        let albums = try await provider(s).artistAlbums(id: "3296287", page: nil).items
        #expect(!albums.isEmpty && albums.map { $0.releaseDate ?? "" } == albums.map { $0.releaseDate ?? "" }.sorted(by: >))
        #expect(query(s.requests.first, "entity") == "album")
    }

    @Test func searchAlbumsAndArtists() async throws {
        let s = stub(["/search": itunesAlbums])
        #expect(try await provider(s).searchAlbums("x", page: nil).items.first?.totalTracks != nil)
        let a = stub(["/search": itunesArtists])
        #expect(try await provider(a).searchArtists("queen", page: nil).items.first?.name == "Queen")
        #expect(query(a.requests.first, "entity") == "musicArtist")
    }

    @Test func badIdsAreNotFoundWithoutAskingApple() async throws {
        let s = stub(["/lookup": itunesSongs])
        await #expect(throws: MusicError.notFound) { try await provider(s).track(id: "abc") }
        #expect(s.requests.isEmpty)
        let empty = stub(["/lookup": #"{"resultCount":0,"results":[]}"#])
        await #expect(throws: MusicError.notFound) { try await provider(empty).track(id: "1") }
        await #expect(throws: MusicError.notFound) { try await provider(empty).albumTracks(id: "1", page: nil) }
        await #expect(throws: MusicError.notFound) { try await provider(empty).artistAlbums(id: "1", page: nil) }
        let four00 = ContractStub { _ in (400, "") }
        await #expect(throws: MusicError.notFound) { try await ITunesProvider(http: http(four00), country: { nil }).track(id: "5") }
    }

    @Test func rateLimitAndServerErrorsAreClear() async throws {
        let limited = ContractStub { _ in (403, "") }
        await #expect(throws: MusicError.rateLimited(retryAfter: nil)) { try await ITunesProvider(http: http(limited), country: { nil }).searchTracks("x", page: nil) }
        let calls = LockedCounter()
        let flaky = ContractStub { _ in calls.next() == 1 ? (502, "") : (200, itunesSongs) }
        #expect(try await ITunesProvider(http: http(flaky), country: { nil }).searchTracks("x", page: nil).items.count == 2)
        let broken = stub(["/search": #"{"oops":1}"#])
        await #expect(throws: MusicError.network("unexpected reply")) { try await provider(broken).searchTracks("x", page: nil) }
    }

    @Test func chartsUseLookupDetailsInChartOrderAndFallBackToTheFeed() async throws {
        let s = ContractStub { r in
            if r.url?.host == "rss.marketingtools.apple.com" { return (200, itunesChart) }
            return (200, itunesChartLookup)
        }
        let sections = try await provider(s, country: "IN").featured()
        let songs = try #require(sections.first)
        #expect(songs.id == "itunes-top-songs" && songs.items.count == 3)
        if case .track(let first) = songs.items[0] { #expect(first.durationMs > 0) } else { Issue.record("expected a track") }
        #expect(s.requests.first?.url?.path.contains("/api/v2/in/music/most-played") == true)
        let noLookup = ContractStub { r in r.url?.host == "rss.marketingtools.apple.com" ? (200, itunesChart) : (500, "") }
        let fallback = try await provider(noLookup, country: "IN").featured()
        if case .track(let t) = fallback[0].items[0] { #expect(t.directStreams == nil && t.durationMs == 0 && !t.title.isEmpty) } else { Issue.record("expected a track") }
        let down = ContractStub { _ in (502, "") }
        await #expect(throws: MusicError.self) { try await provider(down).featured() }
    }

    @Test func storefrontNormalising() {
        #expect(ITunesProvider.storefront("IN") == "in" && ITunesProvider.storefront("us") == "us")
        #expect(ITunesProvider.storefront("USA") == nil && ITunesProvider.storefront("1a") == nil && ITunesProvider.storefront(nil) == nil)
    }
}
