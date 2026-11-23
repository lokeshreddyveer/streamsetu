<!-- atlas-inputs-sha256: fe25f7b17b4e16851bf5654fa4a0d105cd6f9dda9a2b521d339f128e9e6c873a -->
<!-- coverage-body-sha256: 301327745fa4cceee51c6613fdad9d1e75470c6ef3b565fd77e53d4150411077 -->
# Assistant coverage

Generated from the atlas by `AtlasCoverageTests` (set `ATLAS_DOCS_WRITE=1` to rewrite it). Everything Setu can answer about the app is one entry in `macos/Sources/REDDY/Atlas`; this page lists them all. *Reviewed* means the wording was checked against the code by a person or in a test; the rest was written from the code and has not had a second look. Setu answers from these entries with no language model.

## Totals

| Kind | Entries | Reviewed | Mac | iPhone | iPad |
|---|---|---|---|---|---|
| Screens | 121 | 118 | 78 | 45 | 44 |
| Settings pages | 24 | 24 | 8 | 18 | 18 |
| Controls and settings groups | 412 | 368 | 208 | 222 | 222 |
| Settings | 109 | 106 | 101 | 98 | 99 |
| Menu commands | 40 | 40 | 40 | 1 | 1 |
| Keyboard shortcuts | 31 | 31 | 28 | 0 | 3 |
| Context menus | 43 | 43 | 38 | 27 | 27 |
| Gestures and long presses | 35 | 35 | 11 | 24 | 20 |
| Siri and Shortcuts | 7 | 7 | 0 | 7 | 7 |
| How-tos | 65 | 65 | 64 | 61 | 62 |
| Troubleshooting | 23 | 23 | 23 | 21 | 21 |
| About Setu and what is new | 17 | 17 | 14 | 16 | 16 |
| **All** | **927** | **877** | 613 | 540 | 540 |

Entries Setu explains but never changes (app lock, proxy, parental controls and similar): 49.

## Screens

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| screen.accountMenu | Account menu | Top bar > Account menu | explained only | Mac | yes |
| screen.addPlaylist | Add Playlist | File > Add Playlist… | modal addPlaylist | Mac | yes |
| screen.assistant | Setu | Setu button | explained only | Mac, iPhone, iPad | yes |
| screen.channelManager.channels | Channel manager: Channels | Channel manager > Channels | modal channelManager | Mac | yes |
| screen.channelManager.folders | Channel manager: Folders | Channel manager > Folders | modal channelManager | Mac | yes |
| screen.collection.detail | A collection | Home > Collections > a collection | explained only | Mac | yes |
| screen.destination.channelManager | Go to Channel Manager | Channel manager | destination channelManager | Mac | yes |
| screen.destination.collections | Go to Collections | Home > Collections | destination collections | Mac | yes |
| screen.destination.continueWatching | Go to Continue Watching | Home > Continue Watching | destination continueWatching | Mac | yes |
| screen.destination.favorites | Go to Favorites | Home > Favorites | destination favorites | Mac | yes |
| screen.destination.guide | Go to TV Guide | TV Guide | destination guide | Mac | yes |
| screen.destination.history | Go to Recently Watched | Home > Recently Watched | destination history | Mac | yes |
| screen.destination.home | Go to Home | Home > Discover | destination home | Mac | yes |
| screen.destination.liveTV | Go to Live TV | Live TV > All Channels | destination liveTV | Mac | yes |
| screen.destination.movies | Go to Movies | Movies > All Movies | destination movies | Mac | yes |
| screen.destination.playlists | Go to Playlists | Playlists | destination playlists | Mac | yes |
| screen.destination.series | Go to Series | Series > Library | destination series | Mac | yes |
| screen.downloads | Downloads | Settings > Library > Downloads | search downloads | Mac | yes |
| screen.feedback | Send Feedback | Help > Send Feedback | window feedback | Mac | yes |
| screen.filesAndServers | Files and Servers | File > Files and Servers | window files | Mac | yes |
| screen.folderRows | Folder rows | Movies or Series > Folders view | explained only | Mac | yes |
| screen.guide.grid | Guide grid | TV Guide > Grid | tab TV Guide | Mac | yes |
| screen.integrations | Trakt, Debrid and AI | Settings > Library > Integrations | settings page Library | Mac | yes |
| screen.ios.addPlaylist | Add Playlist | Playlists > Add | modal ios.addPlaylist | iPhone, iPad | yes |
| screen.ios.catchUp | Earlier on a channel | Player > Catch-up | explained only | iPhone, iPad | yes |
| screen.ios.collections | Collections | Library > Collections | search collections | iPhone, iPad | yes |
| screen.ios.detail | Title page | A title | modal ios.detail | iPhone, iPad | yes |
| screen.ios.downloads | Downloads | Library > Downloads | search downloads | iPhone, iPad | yes |
| screen.ios.favourites | Favourites | Library > Favourites | search favorites | iPhone, iPad | yes |
| screen.ios.filesAndServers | Files and Servers | Library > Files and Servers | explained only | iPhone, iPad | yes |
| screen.ios.folderRows | Folder rows | Movies or Series > a folder | explained only | iPhone, iPad | yes |
| screen.ios.history | Watch History | Library > Watch History | search history | iPhone, iPad | yes |
| screen.ios.integrations | Trakt, Debrid and AI | Library > Trakt, Debrid and AI | explained only | iPhone, iPad | yes |
| screen.ios.ipadSidebar | iPad sidebar | iPad > Sidebar | explained only | iPad | yes |
| screen.ios.miniPlayer | Mini player | Bottom > Mini player | explained only | iPhone, iPad | yes |
| screen.ios.multiView | Multi-View | Playback > Multi-View | modal ios.multiView | iPhone, iPad | yes |
| screen.ios.onYourDevice | On Your Device | Library > On Your Device | explained only | iPhone, iPad | yes |
| screen.ios.player | Player | Player | modal ios.player | iPhone, iPad | yes |
| screen.ios.player.episodes | Episode list | Player > Episodes | explained only | iPhone, iPad | yes |
| screen.ios.playerOptions | Player options | Player > Options | explained only | iPhone, iPad | yes |
| screen.ios.playlist.editLogin | Change login | Playlists > A playlist > Change Login or Address | explained only | iPhone, iPad | yes |
| screen.ios.playlist.health | Check channels | Playlists > A playlist > Check Channels | explained only | iPhone, iPad | yes |
| screen.ios.programme | Programme | Guide > a programme | explained only | iPhone, iPad | yes |
| screen.ios.settings.backup | Backup and Restore | Settings > Backup and Restore | explained only | iPhone, iPad | yes |
| screen.ios.settings.crashReports | Crash Reports | Settings > About > Crash Reports | settings page about | iPhone, iPad | yes |
| screen.ios.settings.feedback | Send Feedback | Settings > About > Send Feedback | settings page about | iPhone, iPad | yes |
| screen.ios.settings.folders | Folders | Settings > Library and Guide > Folders | settings page library | iPhone, iPad | yes |
| screen.ios.settings.guide | Guide settings | Settings > Subscriptions and Alerts > Guide sources | explained only | iPhone, iPad | yes |
| screen.ios.settings.playlistDetail | Playlist detail | Playlists > a playlist | tab playlists | iPhone, iPad | yes |
| screen.ios.settings.storage | Storage and Maintenance | Settings > Storage and Maintenance | explained only | iPhone, iPad | yes |
| screen.ios.settings.unlockFolders | Unlock Folders | Settings > Parental Controls > Unlock | settings page parental | iPhone, iPad | yes |
| screen.ios.statistics | Statistics | Library > Statistics | search statistics | iPhone, iPad | yes |
| screen.ios.tab.guide | Guide | Guide | tab guide | iPhone, iPad | yes |
| screen.ios.tab.home | Home | Home | tab home | iPhone, iPad | yes |
| screen.ios.tab.library | Library | More > Library | tab library | iPhone, iPad | yes |
| screen.ios.tab.live | Live TV | Live TV | tab live | iPhone, iPad | yes |
| screen.ios.tab.more | More | More | tab more | iPhone | yes |
| screen.ios.tab.movies | Movies | Movies | tab movies | iPhone, iPad | yes |
| screen.ios.tab.playlists | Playlists | More > Playlists | tab playlists | iPhone, iPad | yes |
| screen.ios.tab.search | Search | Search | tab search | iPhone, iPad | yes |
| screen.ios.tab.series | Series | Series | tab series | iPhone, iPad | yes |
| screen.ios.tab.settings | Settings | More > Settings | tab settings | iPhone, iPad | yes |
| screen.ios.tabBar | Tab bar | iPhone > Tab bar | explained only | iPhone | yes |
| screen.ios.tonight | Tonight | Library > Tonight | search tonight | iPhone, iPad | yes |
| screen.ios.watchLater | Watch Later | Library > Watch Later | search watchLater | iPhone, iPad | yes |
| screen.ios.welcome | Welcome | First run | explained only | iPhone, iPad | yes |
| screen.liveTV.channelList | Channel list | Live TV > Channel list | tab Live TV | Mac | yes |
| screen.modal.about | About StreamSetu | StreamSetu menu > About StreamSetu | modal about | Mac | yes |
| screen.modal.unlockRestricted | Unlock restricted content | Account menu > Unlock restricted content | modal unlockRestricted | Mac | yes |
| screen.multiview | Multi-View | Playback > Open Multi-View | window multiview | Mac | yes |
| screen.onYourDevice | On Your Device | File > Files and Servers > On Your Device | window files | Mac, iPhone, iPad | yes |
| screen.onboarding | Welcome and first run | First run | explained only | Mac | yes |
| screen.opening | Opening and What's New | Settings > Appearance > Opening | settings page Appearance | Mac | yes |
| screen.person | Person page | A title > Cast > a person | explained only | Mac | yes |
| screen.player.fullscreen | Full-screen player | Player | explained only | Mac | yes |
| screen.playlist.connection | Playlist connection options | Playlists > a playlist > Connection | modal playlists | Mac | yes |
| screen.playlist.health | Playlist health | Playlists > a playlist > Health | modal playlists | Mac | yes |
| screen.playlistMenu | Playlist menu | Sidebar > Playlist menu | explained only | Mac | yes |
| screen.playlists | Playlists | Library settings > Manage > Playlists | modal playlists | Mac | yes |
| screen.podcasts | Podcasts | Files and Servers > Podcasts | window files | Mac, iPhone, iPad | yes |
| screen.recordings | Recordings | Settings > Library > Recordings | explained only | Mac | yes |
| screen.search | Search | Top bar > Search | search focus | Mac | yes |
| screen.searchResults | Search results | Top bar > Search > Results | explained only | Mac | yes |
| screen.service.host | A streaming service | Top bar > Services | explained only | Mac | no |
| screen.service.the external service | the external service | Top bar > the external service | explained only | Mac | yes |
| screen.service.unavailable | Service unavailable | Top bar > Services | explained only | Mac | no |
| screen.services.list | Services list | Top bar > Services | explained only | Mac | no |
| screen.settings.advanced.legal | Privacy Policy and Terms of Use | Settings > Advanced > About | settings page Advanced | Mac | yes |
| screen.settings.advanced.licenses | Licenses and notices | Settings > Advanced > About > View Licenses | settings page Advanced | Mac | yes |
| screen.settings.channelManager | Channel manager | Library settings > Manage > Channel manager | modal channelManager | Mac | yes |
| screen.settings.guide | Guide settings | Settings > Library > Guide sources | explained only | Mac | yes |
| screen.shortcut.addedThisMonth | Added in 30 Days | Sidebar > Added in 30 Days | sidebar addedThisMonth | Mac | yes |
| screen.shortcut.allChannels | All Channels | Live TV > All Channels | sidebar allChannels | Mac | yes |
| screen.shortcut.allMovies | All Movies | Movies > All Movies | sidebar allMovies | Mac | yes |
| screen.shortcut.collections | Collections | Home > Collections | sidebar collections | Mac | yes |
| screen.shortcut.continueWatching | Continue Watching | Home > Continue Watching | sidebar continueWatching | Mac | yes |
| screen.shortcut.discover | Discover | Home > Discover | sidebar discover | Mac | yes |
| screen.shortcut.favorites | Favorites | Home > Favorites | sidebar favorites | Mac | yes |
| screen.shortcut.featured | Featured | Movies > Featured | sidebar featured | Mac | yes |
| screen.shortcut.library | Library | Series > Library | sidebar library | Mac | yes |
| screen.shortcut.newEpisodes | New Episodes | Series > New Episodes | sidebar newEpisodes | Mac | yes |
| screen.shortcut.recentlyAdded | Recently Added | Sidebar > Recently Added | sidebar recentlyAdded | Mac | yes |
| screen.shortcut.recentlyWatched | Recently Watched | Home > Recently Watched | sidebar recentlyWatched | Mac | yes |
| screen.shortcut.statistics | Statistics | Home > Statistics | sidebar statistics | Mac | yes |
| screen.shortcut.tonight | Tonight | Home > Tonight | sidebar tonight | Mac | yes |
| screen.shortcut.unwatched | Unwatched | Sidebar > Unwatched | sidebar unwatched | Mac | yes |
| screen.shortcut.unwatchedFavorites | Unwatched Favorites | Sidebar > Unwatched Favorites | sidebar unwatchedFavorites | Mac | yes |
| screen.shortcut.watchHistory | Watch History | Home > Watch History | sidebar watchHistory | Mac | yes |
| screen.shortcut.watchLater | Watch Later | Home > Watch Later | sidebar watchLater | Mac | yes |
| screen.shortcuts | Keyboard Shortcuts | Help > Keyboard Shortcuts | window shortcuts | Mac | yes |
| screen.sidebar.folders | Folder list | Sidebar > Folders | explained only | Mac | yes |
| screen.tab.guide | TV Guide | TV Guide | tab TV Guide | Mac | yes |
| screen.tab.home | Home | Home | tab Home | Mac | yes |
| screen.tab.liveTV | Live TV | Live TV | tab Live TV | Mac | yes |
| screen.tab.movies | Movies | Movies | tab Movies | Mac | yes |
| screen.tab.series | Series | Series | tab Series | Mac | yes |
| screen.title.movie | Movie page | Movies > a movie | explained only | Mac | yes |
| screen.title.series | Series page | Series > a series | explained only | Mac | yes |
| screen.tonight | Tonight plan | Home > Tonight | sidebar tonight | Mac | yes |
| screen.window.main | Main window | Window > StreamSetu | window main | Mac | yes |
| screen.window.player | Player window | Playback > Open Player in New Window | window player | Mac | yes |

## Settings pages

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| screen.ios.settings.about | About | Library > Settings > About | settings page about | iPhone, iPad | yes |
| screen.ios.settings.alerts | Subscriptions and Alerts | Library > Settings > Subscriptions and Alerts | settings page alerts | iPhone, iPad | yes |
| screen.ios.settings.appDNS | App DNS | Library > Settings > App DNS | settings page appDNS | iPhone, iPad | yes |
| screen.ios.settings.appearance | Appearance | Library > Settings > Appearance | settings page appearance | iPhone, iPad | yes |
| screen.ios.settings.artwork | Artwork and Details | Library > Settings > Artwork and Details | settings page artwork | iPhone, iPad | yes |
| screen.ios.settings.channelManager | Channel Manager | Library > Settings > Channel Manager | settings page channels | iPhone, iPad | yes |
| screen.ios.settings.health | Playback Health | Library > Settings > Playback Health | settings page health | iPhone, iPad | yes |
| screen.ios.settings.icloud | iCloud Sync | Library > Settings > iCloud Sync | settings page icloud | iPhone, iPad | yes |
| screen.ios.settings.lan | Sync on this network | Library > Settings > Sync on this network | settings page lan | iPhone, iPad | yes |
| screen.ios.settings.library | Library and Guide | Library > Settings > Library and Guide | settings page library | iPhone, iPad | yes |
| screen.ios.settings.parental | Parental Controls | Library > Settings > Parental Controls | settings page parental | iPhone, iPad | yes |
| screen.ios.settings.playback | Playback | Library > Settings > Playback | settings page playback | iPhone, iPad | yes |
| screen.ios.settings.privacyReport | Privacy Report | Library > Settings > Privacy Report | settings page privacyReport | iPhone, iPad | yes |
| screen.ios.settings.profiles | Profiles | Library > Settings > Profiles | settings page profiles | iPhone, iPad | yes |
| screen.ios.settings.proxy | Proxy | Library > Settings > Proxy | settings page proxy | iPhone, iPad | yes |
| screen.ios.settings.vpn | VPN | Library > Settings > VPN | settings page vpn | iPhone, iPad | yes |
| screen.settings.advanced | Advanced settings | Settings > Advanced | settings page Advanced | Mac | yes |
| screen.settings.appearance | Appearance settings | Settings > Appearance | settings page Appearance | Mac | yes |
| screen.settings.backup | Backup and Restore | Settings > Backup and Restore | settings page backup | Mac, iPhone, iPad | yes |
| screen.settings.general | General settings | Settings > General | settings page General | Mac | yes |
| screen.settings.library | Library settings | Settings > Library | settings page Library | Mac | yes |
| screen.settings.playback | Playback settings | Settings > Playback | settings page Playback | Mac | yes |
| screen.settings.privacy | Privacy settings | Settings > Privacy | settings page Privacy | Mac | yes |
| screen.settings.storage | Storage and Maintenance | Settings > Storage and Maintenance | settings page storage | Mac, iPhone, iPad | yes |

## Controls and settings groups

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| control.addSource.type | Choose the kind of playlist | Add Playlist > Type | explained only | Mac | yes |
| control.commandCenter.bulkAction | Bulk action on selected channels | Channel Manager > Channels | explained only | Mac | yes |
| control.commandCenter.favorite | Favourite a channel | Channel Manager > Channels | explained only | Mac | yes |
| control.commandCenter.filterChip | Channel filter chips | Channel Manager > Channels | explained only | Mac | yes |
| control.commandCenter.folderHide | Show or hide a folder | Channel Manager > Folders | explained only | Mac | yes |
| control.commandCenter.folderMove | Move a folder up or down | Channel Manager > Folders | explained only | Mac | yes |
| control.commandCenter.folderScope | Choose which folders to arrange | Channel Manager > Folders | explained only | Mac | yes |
| control.commandCenter.folderSort | Sort folders | Channel Manager > Folders | explained only | Mac | yes |
| control.commandCenter.hide | Hide a channel | Channel Manager > Channels | explained only | Mac | yes |
| control.commandCenter.matchGuide | Match a channel to the guide | Channel Manager > Channels | explained only | Mac | yes |
| control.commandCenter.moveToFolder | Move channels to a folder | Channel Manager > Channels | explained only | Mac | yes |
| control.commandCenter.playlistFilter | Filter channels by playlist | Channel Manager > Channels | explained only | Mac | yes |
| control.commandCenter.restoreDefaults | Restore provider defaults | Channel Manager > Channels | explained only | Mac | yes |
| control.commandCenter.selectAll | Select all channels | Channel Manager > Channels | explained only | Mac | yes |
| control.commandCenter.tabs | Channels or Folders view | Channel Manager | explained only | Mac | yes |
| control.enhancement.consentCancel | Cancel (page option) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.enhancement.consentConfirm | Turn On (page option) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.enhancement.promptAdSkip | Skip ads (first-open card) | Services | explained only | Mac | no |
| control.enhancement.promptDone | Done (page options) | Services | explained only | Mac | no |
| control.enhancement.promptNotNow | Not now (page options) | Services | explained only | Mac | no |
| control.enhancement.promptSetUp | Set up page options | Services | explained only | Mac | no |
| control.enhancement.promptSponsorSkip | Skip sponsor segments (first-open card) | Services | explained only | Mac | no |
| control.enhancement.reload | Reload to apply page options | Services | explained only | Mac | no |
| control.featured.arrow | Featured banner arrows | Movies > Featured banner | explained only | Mac | yes |
| control.featured.dot | Featured banner dots | Movies > Featured banner | explained only | Mac | yes |
| control.featured.moreInfo | More info on a featured title | Movies > Featured banner | explained only | Mac | yes |
| control.featured.play | Play a featured title | Movies > Featured banner | explained only | Mac | yes |
| control.feedback.includeDiagnostics | Include diagnostics in feedback | Help > Send Feedback | explained only | Mac | yes |
| control.feedback.kind | Kind of feedback | Help > Send Feedback | explained only | Mac | yes |
| control.feedback.sendEmail | Send feedback by email | Help > Send Feedback | explained only | Mac | yes |
| control.feedback.sendLog | Send or clear the playback log | Help > Send Feedback | explained only | Mac | yes |
| control.feedback.shareAutomatically | Share playback logs automatically | Help > Send Feedback | explained only | Mac | yes |
| control.files.addFolder | Add a folder | Files and Servers | explained only | Mac, iPhone, iPad | yes |
| control.files.addServer | Add a WebDAV server | Files and Servers | explained only | Mac, iPhone, iPad | yes |
| control.files.browse | Open a folder | Files and Servers | explained only | Mac | yes |
| control.files.play | Play a file | Files and Servers | explained only | Mac | yes |
| control.guide.diagnostics | Refresh all guides | Settings > Library > Guide sources > Refresh all guides | explained only | Mac, iPhone, iPad | yes |
| control.guide.programmeAction | Programme actions | TV Guide > Programme | explained only | Mac | yes |
| control.home.clearMenu | Clear menu | Home | explained only | Mac | yes |
| control.home.collection | Collection | Home > Discover | explained only | Mac, iPhone, iPad | no |
| control.home.collectionDone | Close collection | Home > Discover | explained only | Mac | no |
| control.home.discoverClear | Clear Discover filters | Home > Discover | explained only | Mac | yes |
| control.home.discoverLanguage | Discover language filter | Home > Discover | explained only | Mac | yes |
| control.home.discoverOrder | Discover order | Home > Discover | explained only | Mac | yes |
| control.home.genre | Browse by genre | Home > Discover | explained only | Mac | yes |
| control.home.nowPlayingElsewhere | Play here | Home | explained only | Mac | yes |
| control.home.shelfMode | Shelf mode | Home | explained only | Mac, iPhone, iPad | yes |
| control.ios.about.legal | Privacy Policy, Terms and Licenses | Settings > About > Privacy Policy, Terms and Licenses | explained only | iPhone, iPad | yes |
| control.ios.addPlaylist.back | All connection types | Playlists > Add Playlist > All connection types | explained only | iPhone, iPad | yes |
| control.ios.addPlaylist.chooseFile | Choose a file | Playlists > Add Playlist > Choose a file | explained only | iPhone, iPad | yes |
| control.ios.addPlaylist.connect | Connect | Playlists > Add Playlist > Connect | explained only | iPhone, iPad | yes |
| control.ios.addPlaylist.findTuners | Find Tuners on This Network | Playlists > Add Playlist > Find Tuners on This Network | explained only | iPhone, iPad | yes |
| control.ios.addPlaylist.pickTuner | Found tuner | Playlists > Add Playlist > Found tuner | explained only | iPhone, iPad | yes |
| control.ios.addPlaylist.saveAnyway | Save Anyway | Playlists > Add Playlist > Save Anyway | explained only | iPhone, iPad | yes |
| control.ios.alerts.lookNow | Look Now | Settings > Subscriptions and Alerts > Look Now | explained only | iPhone, iPad | yes |
| control.ios.appDNS.clearCache | Clear DNS Cache | Settings > App DNS > Clear DNS Cache | explained only | iPhone, iPad | yes |
| control.ios.appDNS.localSystem | Use system DNS for local devices | Settings > App DNS > Use system DNS for local devices | explained only | iPhone, iPad | yes |
| control.ios.appDNS.provider | DNS provider | Settings > App DNS > DNS provider | explained only | iPhone, iPad | yes |
| control.ios.appDNS.test | Test App DNS | Settings > App DNS > Test App DNS | explained only | iPhone, iPad | yes |
| control.ios.appearance.customApply | Apply custom theme | Settings > Appearance > Apply custom theme | explained only | iPhone, iPad | yes |
| control.ios.appearance.customReset | Start Again | Settings > Appearance > Start Again | explained only | iPhone, iPad | yes |
| control.ios.appearance.replayStory | Replay the Full Story | Settings > Appearance > Replay the Full Story | explained only | iPhone, iPad | yes |
| control.ios.artwork.cellular | Use mobile data | Settings > Artwork and Details > Use mobile data | explained only | iPhone, iPad | yes |
| control.ios.artwork.matchNow | Match now | Settings > Artwork and Details > Match now | explained only | iPhone, iPad | yes |
| control.ios.artwork.trending | Use the movie database weekly trending | Settings > Artwork and Details > Use the movie database weekly trending | explained only | iPhone, iPad | yes |
| control.ios.backup.apply | Restore | Settings > Backup and Restore > Restore | explained only | iPhone, iPad | yes |
| control.ios.backup.create | Create Backup | Settings > Backup and Restore > Create Backup | explained only | iPhone, iPad | yes |
| control.ios.backup.now | Back Up Now | Settings > Backup and Restore > Back Up Now | explained only | iPhone, iPad | yes |
| control.ios.backup.option | What to include | Settings > Backup and Restore > What to include | explained only | iPhone, iPad | yes |
| control.ios.backup.restore | Restore from a File | Settings > Backup and Restore > Restore from a File | explained only | iPhone, iPad | yes |
| control.ios.backup.restoreAuto | Restore an automatic backup | Settings > Backup and Restore > Restore an automatic backup | explained only | iPhone, iPad | yes |
| control.ios.catchUp.play | Play an earlier programme | Player > Earlier programmes > Play an earlier programme | explained only | iPhone, iPad | yes |
| control.ios.channelManager.autoMatch | Use Automatic Matching | Settings > Channel Manager > Use Automatic Matching | explained only | iPhone, iPad | yes |
| control.ios.channelManager.edit | Edit a channel | Settings > Channel Manager > Edit a channel | explained only | iPhone, iPad | yes |
| control.ios.channelManager.filter | Channel filter | Settings > Channel Manager > Channel filter | explained only | iPhone, iPad | yes |
| control.ios.channelManager.guideEntry | Choose guide entry | Settings > Channel Manager > Choose guide entry | explained only | iPhone, iPad | yes |
| control.ios.channelManager.reset | Reset Changes | Settings > Channel Manager > Reset Changes | explained only | iPhone, iPad | yes |
| control.ios.channelManager.save | Save channel changes | Settings > Channel Manager > Save channel changes | explained only | iPhone, iPad | yes |
| control.ios.chrome.unfold | Show the buttons again | Chrome > Show the buttons again | explained only | iPhone, iPad | yes |
| control.ios.collections.addTo | Add to a collection | A title > Title menu > Add to a collection | explained only | iPhone, iPad | yes |
| control.ios.collections.new | New collection | Library > Collections > New collection | explained only | iPhone, iPad | yes |
| control.ios.collections.rename | Rename collection | Library > Collections > A collection > Rename collection | explained only | iPhone, iPad | yes |
| control.ios.crashReports.deleteAll | Delete All crash reports | Settings > About > Crash Reports > Delete All crash reports | explained only | iPhone, iPad | yes |
| control.ios.crashReports.keep | Keep crash reports | Settings > About > Crash Reports > Keep crash reports | explained only | iPhone, iPad | yes |
| control.ios.detail.closeTrailer | Close trailer | A title > Close trailer | explained only | iPhone, iPad | yes |
| control.ios.detail.episode | Episode | A title > Episode | explained only | iPhone, iPad | yes |
| control.ios.detail.favourite | Favourite | A title > Favourite | explained only | iPhone, iPad | yes |
| control.ios.detail.moreMenu | Title menu | A title > Title menu | explained only | iPhone, iPad | yes |
| control.ios.detail.openSettings | Open Settings (artwork key) | A title > Open Settings (artwork key) | explained only | iPhone, iPad | yes |
| control.ios.detail.overview | More or Less | A title > More or Less | explained only | iPhone, iPad | yes |
| control.ios.detail.season | Season | A title > Season | explained only | iPhone, iPad | yes |
| control.ios.detail.similar | Similar title | A title > Similar title | explained only | iPhone, iPad | yes |
| control.ios.detail.trailer | Trailer | A title > Trailer | explained only | iPhone, iPad | yes |
| control.ios.detail.watchLater | Watch Later | A title > Watch Later | explained only | iPhone, iPad | yes |
| control.ios.downloads.removeAll | Remove All Downloads | Library > Downloads > Remove All Downloads | explained only | iPhone, iPad | yes |
| control.ios.emptyState.action | Empty page button | Components > Empty page button | explained only | iPhone, iPad | yes |
| control.ios.failure.repair | Repair Library | App > Repair Library | explained only | iPhone, iPad | yes |
| control.ios.failure.startFresh | Start Fresh | App > Start Fresh | explained only | iPhone, iPad | yes |
| control.ios.feedback.autoShare | Share playback logs automatically | Settings > About > Send Feedback > Share playback logs automatically | explained only | iPhone, iPad | yes |
| control.ios.feedback.clearLog | Clear Playback Log | Settings > About > Send Feedback > Clear Playback Log | explained only | iPhone, iPad | yes |
| control.ios.feedback.diagnostics | Include diagnostics | Settings > About > Send Feedback > Include diagnostics | explained only | iPhone, iPad | yes |
| control.ios.feedback.sendEmail | Send by Email | Settings > About > Send Feedback > Send by Email | explained only | iPhone, iPad | yes |
| control.ios.feedback.sendLog | Send My Log Now | Settings > About > Send Feedback > Send My Log Now | explained only | iPhone, iPad | yes |
| control.ios.feedback.type | Feedback type | Settings > About > Send Feedback > Feedback type | explained only | iPhone, iPad | yes |
| control.ios.folderRows.more | More | Movies or Series > A folder > More | explained only | iPhone, iPad | yes |
| control.ios.folderRows.openFolder | Open a folder | Movies or Series > A folder > Open a folder | explained only | iPhone, iPad | yes |
| control.ios.folders.section | Folder section | Settings > Library and Guide > Folder section | explained only | iPhone, iPad | yes |
| control.ios.guide.jump | Jump in time | Guide > Jump in time | explained only | iPhone, iPad | yes |
| control.ios.guide.programme | Programme | Guide > Programme | explained only | iPhone, iPad | yes |
| control.ios.guide.scope | Which channels | Guide > Which channels | explained only | iPhone, iPad | yes |
| control.ios.guide.watch | Watch a channel | Guide > Watch a channel | explained only | iPhone, iPad | yes |
| control.ios.health.reset | Reset These Numbers | Settings > Playback Health > Reset These Numbers | explained only | iPhone, iPad | yes |
| control.ios.health.sendLog | Send My Log | Settings > Playback Health > Send My Log | explained only | iPhone, iPad | yes |
| control.ios.health.useEngine | Use the faster engine | Settings > Playback Health > Use the faster engine | explained only | iPhone, iPad | yes |
| control.ios.history.clear | Clear Watch History | Library > Watch History > Clear Watch History | explained only | iPhone, iPad | yes |
| control.ios.home.channel | Channel tile | Home > Channel tile | explained only | iPhone, iPad | yes |
| control.ios.home.continue | Continue Watching card | Home > Continue Watching card | explained only | iPhone, iPad | yes |
| control.ios.home.genre | Genre chip | Home > Genre chip | explained only | iPhone, iPad | yes |
| control.ios.home.hero | Featured banner | Home > Featured banner | explained only | iPhone, iPad | yes |
| control.ios.home.search | Search | Home > Search | explained only | iPhone, iPad | yes |
| control.ios.home.seeAll | See all | Home > See all | explained only | iPhone, iPad | yes |
| control.ios.home.shuffle | Shuffle recommendations | Home > Shuffle recommendations | explained only | iPhone, iPad | yes |
| control.ios.home.upNext | Next episode card | Home > Next episode card | explained only | iPhone, iPad | yes |
| control.ios.icloud.erase | Erase iCloud Data | Settings > iCloud Sync > Erase iCloud Data | explained only | iPhone, iPad | yes |
| control.ios.icloud.syncNow | Sync Now | Settings > iCloud Sync > Sync Now | explained only | iPhone, iPad | yes |
| control.ios.ipad.folder | Folder in the column | iPad > Folders > Folder in the column | explained only | iPhone, iPad | yes |
| control.ios.ipad.folderColumn | Show or hide folders | iPad > Folders > Show or hide folders | explained only | iPhone, iPad | yes |
| control.ios.ipad.searchShortcut | Search shortcut | iPad > Sidebar > Search shortcut | explained only | iPhone, iPad | yes |
| control.ios.lan.add | Add a Device | Settings > Sync on this network > Add a Device | explained only | iPhone, iPad | yes |
| control.ios.lan.syncNow | Sync Now | Settings > Sync on this network > Sync Now | explained only | iPhone, iPad | yes |
| control.ios.library.folderMenu | Folder filter | Movies or Series > Folder filter | explained only | iPhone, iPad | yes |
| control.ios.library.search | Search | Movies or Series > Search | explained only | iPhone, iPad | yes |
| control.ios.library.shelf | Shelf chip | Movies or Series > Shelf chip | explained only | iPhone, iPad | yes |
| control.ios.library.sortMenu | Sort and view | Movies or Series > Sort and view | explained only | iPhone, iPad | yes |
| control.ios.list.edit | Edit or Done | Library > Edit or Done | explained only | iPhone, iPad | yes |
| control.ios.list.moreMenu | More (list menu) | Library > More (list menu) | explained only | iPhone, iPad | yes |
| control.ios.list.remove | Remove from list | Library > Remove from list | explained only | iPhone, iPad | yes |
| control.ios.list.sort | Sort | Library > Sort | explained only | iPhone, iPad | yes |
| control.ios.live.categories | Folders | Live TV > Folders | explained only | iPhone, iPad | yes |
| control.ios.live.favouritesOnly | Favourites only | Live TV > Favourites only | explained only | iPhone, iPad | yes |
| control.ios.live.goToNumber | Go to channel number | Live TV > Go to channel number | explained only | iPhone, iPad | yes |
| control.ios.live.group | Group chip | Live TV > Group chip | explained only | iPhone, iPad | yes |
| control.ios.live.guide | TV Guide | Live TV > TV Guide | explained only | iPhone, iPad | yes |
| control.ios.live.lists | Channel lists | Live TV > Channel lists | explained only | iPhone, iPad | yes |
| control.ios.live.multiView | Multi-View | Live TV > Multi-View | explained only | iPhone, iPad | yes |
| control.ios.live.newGroup | New Group | Live TV > New Group | explained only | iPhone, iPad | yes |
| control.ios.live.retry | Retry | Live TV > Retry | explained only | iPhone, iPad | yes |
| control.ios.live.retryPage | Retry loading more | Live TV > Retry loading more | explained only | iPhone, iPad | yes |
| control.ios.live.search | Search live channels | Live TV > Search live channels | explained only | iPhone, iPad | yes |
| control.ios.live.tiles | List or tiles | Live TV > List or tiles | explained only | iPhone, iPad | yes |
| control.ios.live.viewMode | Folders or channel list | Live TV > Folders or channel list | explained only | iPhone, iPad | yes |
| control.ios.miniPlayer.playPause | Mini player play or pause | Player > Mini player play or pause | explained only | iPhone, iPad | yes |
| control.ios.miniPlayer.stop | Mini player stop | Player > Mini player stop | explained only | iPhone, iPad | yes |
| control.ios.multiView.add | Add channel | Playback > Multi-View > Add channel | explained only | iPhone, iPad | yes |
| control.ios.multiView.menu | Multi-View menu | Playback > Multi-View > Multi-View menu | explained only | iPhone, iPad | yes |
| control.ios.multiView.mute | Mute | Playback > Multi-View > Mute | explained only | iPhone, iPad | yes |
| control.ios.multiView.pickChannel | Pick a channel | Playback > Multi-View > Pick a channel | explained only | iPhone, iPad | yes |
| control.ios.multiView.pickerFilter | All channels or Favourites | Playback > Multi-View > All channels or Favourites | explained only | iPhone, iPad | yes |
| control.ios.multiView.preset | Saved set | Playback > Multi-View > Saved set | explained only | iPhone, iPad | yes |
| control.ios.multiView.tileRetry | Try Again or Change | Playback > Multi-View > Try Again or Change | explained only | iPhone, iPad | yes |
| control.ios.parental.lockFolder | Lock a folder | Settings > Parental Controls > Lock a folder | explained only | iPhone, iPad | yes |
| control.ios.parental.removePIN | Remove PIN | Settings > Parental Controls > Remove PIN | explained only | iPhone, iPad | yes |
| control.ios.parental.savePIN | Save PIN | Settings > Parental Controls > Save PIN | explained only | iPhone, iPad | yes |
| control.ios.parental.unlockConfirm | Unlock | Settings > Parental Controls > Unlock | explained only | iPhone, iPad | yes |
| control.ios.playback.useMPV | Use MPV | Settings > Playback > Use MPV | explained only | iPhone, iPad | yes |
| control.ios.player.addSubtitle | Add subtitle file | Player > Add subtitle file | explained only | iPhone, iPad | yes |
| control.ios.player.aspect | Picture shape | Player > Picture shape | explained only | iPhone, iPad | yes |
| control.ios.player.audioChip | Audio chip | Player > Audio chip | explained only | iPhone, iPad | yes |
| control.ios.player.audioTrack | Audio track | Player > Audio track | explained only | iPhone, iPad | yes |
| control.ios.player.bottomButtons | Channels, Guide and Next Episode | Player > Channels, Guide and Next Episode | explained only | iPhone, iPad | yes |
| control.ios.player.channelFolders | Channel folders menu | Player > Channel folders menu | explained only | iPhone, iPad | yes |
| control.ios.player.channelListClose | Close channel list | Player > Close channel list | explained only | iPhone, iPad | yes |
| control.ios.player.channelRow | Channel in the list | Player > Channel in the list | explained only | iPhone, iPad | yes |
| control.ios.player.chapter | Chapter | Player > Chapter | explained only | iPhone, iPad | yes |
| control.ios.player.close | Close player | Player > Close player | explained only | iPhone, iPad | yes |
| control.ios.player.episodeRow | Episode | Player > Episode | explained only | iPhone, iPad | yes |
| control.ios.player.episodeSeason | Season | Player > Season | explained only | iPhone, iPad | yes |
| control.ios.player.failureClose | Close player after a failure | Player > Close player after a failure | explained only | iPhone, iPad | yes |
| control.ios.player.failureEditLogin | Edit Login | Player > Edit Login | explained only | iPhone, iPad | yes |
| control.ios.player.failureNextChannel | Next Channel | Player > Next Channel | explained only | iPhone, iPad | yes |
| control.ios.player.failureRetry | Try Again | Player > Try Again | explained only | iPhone, iPad | yes |
| control.ios.player.failureSendLog | Send My Log (player error) | Player > Send My Log (player error) | explained only | iPhone, iPad | yes |
| control.ios.player.findSubtitles | Find subtitles online | Player > Find subtitles online | explained only | iPhone, iPad | yes |
| control.ios.player.fitFill | Fit or Fill | Player > Fit or Fill | explained only | iPhone, iPad | yes |
| control.ios.player.frameStep | Step a frame | Player > Step a frame | explained only | iPhone, iPad | yes |
| control.ios.player.goToTime | Go to a time | Player > Go to a time | explained only | iPhone, iPad | yes |
| control.ios.player.loop | Repeat a section | Player > Repeat a section | explained only | iPhone, iPad | yes |
| control.ios.player.miniGuideClose | Close guide card | Player > Close guide card | explained only | iPhone, iPad | yes |
| control.ios.player.miniGuideRemind | Programme reminder | Player > Programme reminder | explained only | iPhone, iPad | yes |
| control.ios.player.moreMenu | Player menu | Player > Player menu | explained only | iPhone, iPad | yes |
| control.ios.player.nextChannel | Next channel | Player > Next channel | explained only | iPhone, iPad | yes |
| control.ios.player.nextEpisodeDismiss | Dismiss next episode card | Player > Dismiss next episode card | explained only | iPhone, iPad | yes |
| control.ios.player.nextEpisodePlay | Play Now (next episode) | Player > Play Now (next episode) | explained only | iPhone, iPad | yes |
| control.ios.player.numberPad | Channel number key | Player > Channel number key | explained only | iPhone, iPad | yes |
| control.ios.player.pictureChip | Picture chip | Player > Picture chip | explained only | iPhone, iPad | yes |
| control.ios.player.playPause | Play or pause | Player > Play or pause | explained only | iPhone, iPad | yes |
| control.ios.player.previousChannel | Previous channel | Player > Previous channel | explained only | iPhone, iPad | yes |
| control.ios.player.resetPicture | Reset picture tuning | Player > Reset picture tuning | explained only | iPhone, iPad | yes |
| control.ios.player.resumeDismiss | Dismiss resume card | Player > Dismiss resume card | explained only | iPhone, iPad | yes |
| control.ios.player.saveFrame | Save frame to Photos | Player > Save frame to Photos | explained only | iPhone, iPad | yes |
| control.ios.player.search | Search from the player | Player > Search from the player | explained only | iPhone, iPad | yes |
| control.ios.player.sharePlay | Watch together (SharePlay) | Player > Watch together (SharePlay) | explained only | iPhone, iPad | yes |
| control.ios.player.skip | Skip button | Player > Skip button | explained only | iPhone, iPad | yes |
| control.ios.player.skipBack | Back 10 seconds | Player > Back 10 seconds | explained only | iPhone, iPad | yes |
| control.ios.player.skipForward | Forward 30 seconds | Player > Forward 30 seconds | explained only | iPhone, iPad | yes |
| control.ios.player.speed | Speed | Player > Speed | explained only | iPhone, iPad | yes |
| control.ios.player.speedChip | Speed chip | Player > Speed chip | explained only | iPhone, iPad | yes |
| control.ios.player.startOver | Start over | Player > Start over | explained only | iPhone, iPad | yes |
| control.ios.player.stopWaiting | Stop waiting | Player > Stop waiting | explained only | iPhone, iPad | yes |
| control.ios.player.subtitleChip | Subtitle chip | Player > Subtitle chip | explained only | iPhone, iPad | yes |
| control.ios.player.subtitleStyle | Subtitle size presets | Player > Subtitle size presets | explained only | iPhone, iPad | yes |
| control.ios.player.subtitleTrack | Subtitle track | Player > Subtitle track | explained only | iPhone, iPad | yes |
| control.ios.player.syncNudge | Sound sync and subtitle timing | Player > Sound sync and subtitle timing | explained only | iPhone, iPad | yes |
| control.ios.player.tourDone | Got it | Player > Got it | explained only | iPhone, iPad | yes |
| control.ios.player.unlockControls | Unlock controls | Player > Unlock controls | explained only | iPhone, iPad | yes |
| control.ios.player.volumeBoost | Volume boost | Player > Volume boost | explained only | iPhone, iPad | yes |
| control.ios.playlist.authKind | Sign-in type | Playlists > A playlist > Sign-in type | explained only | iPhone, iPad | yes |
| control.ios.playlist.changeLogin | Change Login or Address | Playlists > A playlist > Change Login or Address | explained only | iPhone, iPad | yes |
| control.ios.playlist.checkChannels | Check Channels | Playlists > A playlist > Check Channels | explained only | iPhone, iPad | yes |
| control.ios.playlist.delete | Delete Playlist | Playlists > A playlist > Delete Playlist | explained only | iPhone, iPad | yes |
| control.ios.playlist.enabled | Enabled | Playlists > A playlist > Enabled | explained only | iPhone, iPad | yes |
| control.ios.playlist.guideFile | Use a Guide File | Playlists > A playlist > Use a Guide File | explained only | iPhone, iPad | yes |
| control.ios.playlist.hideDead | Hide dead channels | Playlists > A playlist > Hide dead channels | explained only | iPhone, iPad | yes |
| control.ios.playlist.makeActive | Make This the Active Playlist | Playlists > A playlist > Make This the Active Playlist | explained only | iPhone, iPad | yes |
| control.ios.playlist.refresh | Refresh Now | Playlists > A playlist > Refresh Now | explained only | iPhone, iPad | yes |
| control.ios.playlist.runCheck | Check Channels now | Playlists > A playlist > Check Channels now | explained only | iPhone, iPad | yes |
| control.ios.playlist.saveHeaders | Save Headers | Playlists > A playlist > Save Headers | explained only | iPhone, iPad | yes |
| control.ios.playlist.saveLogin | Save login | Playlists > A playlist > Save login | explained only | iPhone, iPad | yes |
| control.ios.playlists.add | Add Playlist | Playlists > Add Playlist | explained only | iPhone, iPad | yes |
| control.ios.playlists.refreshAll | Refresh All | Playlists > Refresh All | explained only | iPhone, iPad | yes |
| control.ios.playlists.use | Use this playlist | Playlists > Use this playlist | explained only | iPhone, iPad | yes |
| control.ios.programme.archive | Watch from the Archive | Guide > Watch from the Archive | explained only | iPhone, iPad | yes |
| control.ios.programme.remind | Remind Me | Guide > Remind Me | explained only | iPhone, iPad | yes |
| control.ios.programme.watch | Watch Now | Guide > Watch Now | explained only | iPhone, iPad | yes |
| control.ios.queue.menu | Up Next queue menu | A title > Title menu > Up Next queue menu | explained only | iPhone, iPad | yes |
| control.ios.statistics.range | Statistics range | Library > Statistics > Statistics range | explained only | iPhone, iPad | yes |
| control.ios.statistics.reset | Reset Statistics | Library > Statistics > Reset Statistics | explained only | iPhone, iPad | yes |
| control.ios.storage.clearArtwork | Clear Artwork Cache | Settings > Storage and Maintenance > Clear Artwork Cache | explained only | iPhone, iPad | yes |
| control.ios.storage.clearHistory | Clear Watch History | Settings > Storage and Maintenance > Clear Watch History | explained only | iPhone, iPad | yes |
| control.ios.storage.clearTemp | Clear Temporary Files | Settings > Storage and Maintenance > Clear Temporary Files | explained only | iPhone, iPad | yes |
| control.ios.storage.integrity | Check Database Integrity | Settings > Storage and Maintenance > Check Database Integrity | explained only | iPhone, iPad | yes |
| control.ios.storage.optimize | Optimize Database | Settings > Storage and Maintenance > Optimize Database | explained only | iPhone, iPad | yes |
| control.ios.storage.rebuildSearch | Rebuild Search Index | Settings > Storage and Maintenance > Rebuild Search Index | explained only | iPhone, iPad | yes |
| control.ios.storage.removeEverything | Remove Everything | Settings > Storage and Maintenance > Remove Everything | explained only | iPhone, iPad | yes |
| control.ios.storage.report | Create Diagnostic Report | Settings > Storage and Maintenance > Create Diagnostic Report | explained only | iPhone, iPad | yes |
| control.ios.tonight.play | Play from Tonight | Library > Tonight > Play from Tonight | explained only | iPhone, iPad | yes |
| control.ios.welcome.paste | Paste | Welcome > Paste | explained only | iPhone, iPad | yes |
| control.ios.welcome.pasteSubmit | Continue with the pasted address | Welcome > Continue with the pasted address | explained only | iPhone, iPad | yes |
| control.ios.welcome.restore | Restore from iCloud | Welcome > Restore from iCloud | explained only | iPhone, iPad | yes |
| control.ios.welcome.segment | Option | Welcome > Option | explained only | iPhone, iPad | yes |
| control.ios.welcome.tile | Connection type tile | Welcome > Connection type tile | explained only | iPhone, iPad | yes |
| control.library.filter | Library filters | Movies > Sort menu | explained only | Mac, iPhone, iPad | yes |
| control.library.viewMode | Folders or titles view | Movies | explained only | Mac | yes |
| control.liveTV.catchUp | Watch from the start | Live TV | explained only | Mac | yes |
| control.liveTV.favorite | Favourite a channel | Live TV | explained only | Mac | yes |
| control.liveTV.fullScreen | Full screen | Live TV | explained only | Mac | yes |
| control.liveTV.listFilter | Channel list filter | Live TV | explained only | Mac | yes |
| control.liveTV.streams | Streams menu | Live TV | explained only | Mac | yes |
| control.logging.share | Share logs notice | Notices | explained only | Mac | yes |
| control.multiView.addChannel | Add a channel to Multi-View | Multi-View | explained only | Mac | yes |
| control.multiView.closeAll | Close all tiles | Multi-View | explained only | Mac | yes |
| control.multiView.layout | Multi-View layout | Multi-View | explained only | Mac | yes |
| control.multiView.muteAll | Mute all | Multi-View | explained only | Mac | yes |
| control.multiView.sets | Saved sets of channels | Multi-View | explained only | Mac | yes |
| control.multiView.tileButton | Tile buttons | Multi-View | explained only | Mac | yes |
| control.multiView.tileRetry | Retry or change a tile's channel | Multi-View | explained only | Mac | yes |
| control.nav.the external service | the external service tab | Top bar | explained only | Mac | no |
| control.nav.service | Service tab | Top bar | explained only | Mac | no |
| control.nav.service.reload | Reload a service | Top bar | explained only | Mac | no |
| control.nav.streamsetu | StreamSetu item | Top bar | explained only | Mac | no |
| control.the external service.dismissNotice | Dismiss notice (the external service) | the external service | explained only | Mac | no |
| control.the external service.openBlocked | Open blocked link in browser | the external service | explained only | Mac | no |
| control.the external service.openBrowser | Open in Default Browser (the external service) | the external service | explained only | Mac | no |
| control.the external service.retry | Try Again (the external service) | the external service | explained only | Mac | no |
| control.page.sort | Sort menu | Pages | explained only | Mac | yes |
| control.player.audio | Audio menu | Player | explained only | Mac | yes |
| control.player.back | Back from the player | Player | explained only | Mac | yes |
| control.player.backToLive | Back to live | Player | explained only | Mac | yes |
| control.player.bufferingHint | Buffering help | Player | explained only | Mac | yes |
| control.player.channelPanel | Channels and guide panel | Player | explained only | Mac | yes |
| control.player.engineSwitch | Player engine menu | Player > Engine | explained only | Mac | yes |
| control.player.errorCard | Playback problem card | Player | explained only | Mac | yes |
| control.player.expanded | Now Playing popup | Player | explained only | Mac | yes |
| control.player.externalPlayer | Open in another player | Player | explained only | Mac | yes |
| control.player.extras | More player controls | Player | explained only | Mac | yes |
| control.player.goLive | Go to live | Player | explained only | Mac | yes |
| control.player.miniButtons | Mini player buttons | Player > Bottom bar | explained only | Mac | yes |
| control.player.miniExpand | Expand the mini player | Player > Bottom bar | explained only | Mac | yes |
| control.player.overflow | Player overflow menu | Player | explained only | Mac | yes |
| control.player.pip | Picture in Picture | Player | explained only | Mac | yes |
| control.player.quality | Quality menu | Player | explained only | Mac | yes |
| control.player.queue | Queue menu | Player | explained only | Mac | yes |
| control.player.record | Record | Player | explained only | Mac | yes |
| control.player.resumeCard | Resume card | Player | explained only | Mac | yes |
| control.player.screenshot | Save a screenshot | Player | explained only | Mac | yes |
| control.player.search | Search from the player | Player | explained only | Mac | yes |
| control.player.skipButton | Skip button | Player | explained only | Mac | yes |
| control.player.speed | Speed menu | Player | explained only | Mac | yes |
| control.player.subtitles | Subtitles menu | Player | explained only | Mac | yes |
| control.player.surface | Click the picture | Player | explained only | Mac | yes |
| control.player.tools | Tools menu | Player | explained only | Mac | yes |
| control.player.upNextCard | Up next card | Player | explained only | Mac | yes |
| control.player.videoSize | Video size menu | Player | explained only | Mac | yes |
| control.podcasts.follow | Follow or unfollow a podcast | Files and Servers > Podcasts | explained only | Mac | yes |
| control.podcasts.play | Play a podcast episode | Files and Servers > Podcasts | explained only | Mac | yes |
| control.search.askAI | Ask AI for picks | Search | explained only | Mac, iPhone, iPad | yes |
| control.search.idea | Search ideas | Search | explained only | Mac, iPhone, iPad | yes |
| control.series.seasonPicker | Season picker | Series > Title page | explained only | Mac | yes |
| control.service.dismissNotice | Dismiss notice (service) | Services | explained only | Mac | no |
| control.service.openBlocked | Open blocked link in browser | Services | explained only | Mac | no |
| control.service.openBrowser | Open in Default Browser (service) | Services | explained only | Mac | no |
| control.service.retry | Try Again (service) | Services | explained only | Mac | no |
| control.service.returnHome | Return to StreamSetu | Services | explained only | Mac | no |
| control.services.clearData | Clear a service's data (top bar) | Top bar | explained only | Mac | no |
| control.services.filter | Filter services | Top bar > Services | explained only | Mac | no |
| control.services.menu | Services menu | Top bar | explained only | Mac | no |
| control.services.move | Move a pinned service | Top bar | explained only | Mac | no |
| control.services.open | Open a service | Top bar > Services | explained only | Mac | no |
| control.services.pillmenu | Service pill menu | Top bar | explained only | Mac | no |
| control.services.pin | Pin or unpin a service | Top bar > Services | explained only | Mac | no |
| control.services.section | Services list section | Top bar > Services | explained only | Mac | no |
| control.settings.artworkTrending | Use the movie database weekly trending | Settings > Library > Artwork and details | explained only | Mac | yes |
| control.settings.backupContents | What a backup contains | Settings > Library > Backup | explained only | Mac | yes |
| control.settings.checkForUpdates | Check for updates | Settings > Advanced > About | explained only | Mac | yes |
| control.settings.clearArtworkCache | Clear artwork cache | Settings > Advanced > Reset | explained only | Mac | yes |
| control.settings.clearHistory | Clear viewing history | Settings > Advanced > Reset | explained only | Mac | yes |
| control.settings.clearSearchHistory | Clear search history | Settings > Library > Search index | explained only | Mac | yes |
| control.settings.copyReport | Copy diagnostics report | Settings > Advanced > Diagnostics | explained only | Mac | yes |
| control.settings.crashReports | Crash reports | Settings > Advanced > About | explained only | Mac | yes |
| control.settings.enhancementAdSkip | Skip ads (page option) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.enhancementPromptReset | Show the first-open prompt again | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.enhancementReload | Reload to apply page options (Settings) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.enhancementSponsorSkip | Skip sponsor segments (page option) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.icloudErase | Erase iCloud data | Settings > General > iCloud | explained only | Mac | yes |
| control.settings.icloudSyncNow | Sync with iCloud now | Settings > General > iCloud | explained only | Mac | yes |
| control.settings.lanAddDevice | Add a device to sync with | Settings > General > Sync on this network | explained only | Mac | yes |
| control.settings.lanForget | Forget a paired device | Settings > General > Sync on this network | explained only | Mac | yes |
| control.settings.lanPairConfirm | Confirm pairing | Settings > General > Sync on this network | explained only | Mac | yes |
| control.settings.lanPairDevice | Pair with a nearby device | Settings > General > Sync on this network | explained only | Mac | yes |
| control.settings.lanSyncNow | Sync on this network now | Settings > General > Sync on this network | explained only | Mac | yes |
| control.settings.moreSources | More sources | Settings > Library > More sources | explained only | Mac | yes |
| control.settings.refreshNow | Refresh playlists now | Settings > Library > Catalog | explained only | Mac | yes |
| control.settings.removeEverything | Remove all playlists and data | Settings > Advanced > Remove everything | explained only | Mac | yes |
| control.settings.resetAllPreferences | Reset all preferences | Settings > Advanced > Reset | explained only | Mac | yes |
| control.settings.resetAppearance | Reset appearance | Settings > Advanced > Reset | explained only | Mac | yes |
| control.settings.resetPlayback | Reset playback preferences | Settings > Advanced > Reset | explained only | Mac | yes |
| control.settings.restorePlaybackDefaults | Restore playback defaults | Settings > Playback > Troubleshooting | explained only | Mac | yes |
| control.settings.revealLogs | Reveal logs | Settings > Advanced > Diagnostics | explained only | Mac | yes |
| control.settings.reviewEPG | Review guide mappings | Settings > Library > Programme guide | explained only | Mac | yes |
| control.settings.saveReport | Save diagnostics report | Settings > Advanced > Diagnostics | explained only | Mac | yes |
| control.settings.savedLoginsNewSet | Start a new set of saved logins | Settings > Privacy > Saved logins | explained only | Mac | yes |
| control.settings.servicesClear | Clear a service's data | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesDiagnosticsClear | Clear | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesDiagnosticsCopy | Copy hosts | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesMove | Move a service (Settings) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesOpen | Open a service (Settings) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesPin | Pin a service (Settings) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesReset | Reset the top row order | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesRow | Streaming service row | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.showDataFolder | Show data folder | Settings > Advanced > About | explained only | Mac | yes |
| control.settings.testTmdbKey | Test the the movie database key | Settings > Library > Artwork and details | explained only | Mac | yes |
| control.shelf.scrollArrow | Shelf arrows | Home > Shelves | explained only | Mac | yes |
| control.sidebar.collapse | Collapse the sidebar | Sidebar | explained only | Mac | yes |
| control.title.folderPath | Open the folder a title is in | Title page | explained only | Mac, iPhone, iPad | yes |
| control.title.franchise | Films in the same franchise | Title page | explained only | Mac, iPhone, iPad | yes |
| control.title.otherLanguages | Other languages | Title page | explained only | Mac, iPhone, iPad | no |
| control.title.trailer | Watch the trailer | Title page | explained only | Mac, iPhone, iPad | yes |
| control.title.version | Choose a version | Title page | explained only | Mac, iPhone, iPad | yes |
| screen.settings.advanced.about | About | Settings > Advanced > About | settings page Advanced | Mac | yes |
| screen.settings.advanced.diagnostics | Diagnostics | Settings > Advanced > Diagnostics | settings page Advanced | Mac | yes |
| screen.settings.advanced.removeEverything | Remove everything | Settings > Advanced > Remove everything | settings page Advanced | Mac | yes |
| screen.settings.advanced.reset | Reset | Settings > Advanced > Reset | settings page Advanced | Mac | yes |
| screen.settings.advanced.updates | Check for Updates | Settings > Advanced > About > Updates | settings page Advanced | Mac, direct download only | yes |
| screen.settings.appearance.appearance | Appearance | Settings > Appearance > Appearance | settings page Appearance | Mac | yes |
| screen.settings.appearance.theme | Theme | Settings > Appearance > Theme | settings page Appearance | Mac | yes |
| screen.settings.artwork | Artwork and details | Settings > Library > Artwork and details | settings page Library | Mac, iPhone, iPad | yes |
| screen.settings.general.atLaunch | At launch | Settings > General > At launch | settings page General | Mac | yes |
| screen.settings.general.browsing | Browsing | Settings > General > Browsing | settings page General | Mac | yes |
| screen.settings.general.notifications | Notifications | Settings > General > Notifications | settings page General | Mac | yes |
| screen.settings.keywordAlerts | Guide alerts | Settings > Library > Guide alerts | settings page Library | Mac, iPhone, iPad | yes |
| screen.settings.library.backup | Backup | Settings > Library > Backup | settings page Library | Mac | yes |
| screen.settings.library.cast | Cast and directors | Settings > Library > Cast and directors | settings page Library | Mac | yes |
| screen.settings.library.catalog | Catalog | Settings > Library > Catalog | settings page Library | Mac | yes |
| screen.settings.library.database | Database | Settings > Library > Database | settings page Library | Mac | yes |
| screen.settings.library.downloads | Downloads | Settings > Library > Downloads | settings page Library | Mac | yes |
| screen.settings.library.guide | Programme guide | Settings > Library > Programme guide | settings page Library | Mac | yes |
| screen.settings.library.icloud | iCloud | Settings > Library > iCloud | settings page Library | Mac | yes |
| screen.settings.library.integrations | Integrations | Settings > Library > Integrations | settings page Library | Mac | yes |
| screen.settings.library.lan | Sync on this network | Settings > Library > Sync on this network | settings page Library | Mac | yes |
| screen.settings.library.maintenance | Maintenance | Settings > Library > Maintenance | settings page Library | Mac | yes |
| screen.settings.library.manage | Manage | Settings > Library > Manage | settings page Library | Mac | yes |
| screen.settings.library.recordings | Recordings | Settings > Library > Recordings | settings page Library | Mac | yes |
| screen.settings.library.searchIndex | Search index | Settings > Library > Search index | settings page Library | Mac | yes |
| screen.settings.library.storage | Storage | Settings > Library > Storage | settings page Library | Mac | yes |
| screen.settings.library.subscriptions | Subscriptions | Settings > Library > Subscriptions | settings page Library | Mac | yes |
| screen.settings.parental | Parental controls | Settings > Privacy > Parental controls | settings page Privacy | Mac, iPhone, iPad | yes |
| screen.settings.playback.audio | Audio | Settings > Playback > Audio | settings page Playback | Mac | yes |
| screen.settings.playback.behaviour | Behaviour | Settings > Playback > Behaviour | settings page Playback | Mac | yes |
| screen.settings.playback.buffering | Buffering | Settings > Playback > Buffering | settings page Playback | Mac | yes |
| screen.settings.playback.liveTV | Live TV | Settings > Playback > Live TV | settings page Playback | Mac | yes |
| screen.settings.playback.playerEngine | Player engine | Settings > Playback > Player engine | settings page Playback | Mac | yes |
| screen.settings.playback.remembered | Remembered choices | Settings > Playback > Remembered choices | settings page Playback | Mac | yes |
| screen.settings.playback.subtitles | Subtitles | Settings > Playback > Subtitles | settings page Playback | Mac | yes |
| screen.settings.playback.subtitlesOnline | Subtitles online | Settings > Playback > Subtitles online | settings page Playback | Mac | yes |
| screen.settings.playback.video | Video | Settings > Playback > Video | settings page Playback | Mac | yes |
| screen.settings.privacy.appDNS | App DNS | Settings > Privacy > App DNS | settings page Privacy | Mac | yes |
| screen.settings.privacy.appLock | App lock | Settings > Privacy > App lock | settings page Privacy | Mac | yes |
| screen.settings.privacy.proxy | Proxy | Settings > Privacy > Proxy | settings page Privacy | Mac | yes |
| screen.settings.privacy.savedLogins | Saved logins | Settings > Privacy > Saved logins | settings page Privacy | Mac | yes |
| screen.settings.privacy.vpn | VPN | Settings > Privacy > VPN | settings page Privacy | Mac | yes |
| screen.settings.privacyReport | Privacy report | Settings > Privacy > Privacy report | settings page Privacy | Mac, iPhone, iPad | yes |
| screen.settings.profiles | Profiles | Settings > Library > Profiles | settings page Library | Mac, iPhone, iPad | yes |

## Settings

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| setting.accent | Accent colour | Settings > Appearance > Appearance | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.aiProvider | AI assistant provider | Settings > Library > AI assistant | settings page Library | Mac, iPhone, iPad | yes |
| setting.appDNS | App DNS | Settings > Privacy > App DNS | settings page Privacy | Mac, iPhone, iPad | yes |
| setting.appLock | App lock | Settings > Privacy > App lock | settings page Privacy | Mac, iPhone, iPad | yes |
| setting.artworkBackground | Match artwork in the background | Settings > Library > Artwork and details | settings page Library | Mac, iPhone, iPad | yes |
| setting.askAIJudge | Let the AI pick the best of the matches | Settings > Library > AI assistant | settings page Library | Mac, iPhone, iPad | yes |
| setting.audioOutputUID | Audio output device | Settings > Playback > Audio > Output device | settings page Playback | Mac | yes |
| setting.audioProcessing | Volume normalization | Settings > Playback > Advanced audio | settings page Playback | Mac, iPhone, iPad | yes |
| setting.autoBackup | Back up automatically | Settings > Library > Backup | settings page Library | Mac, iPhone, iPad | yes |
| setting.autoPlayNextEpisode | Play next episode automatically | Settings > Playback > Behaviour | settings page Playback | Mac, iPhone, iPad | yes |
| setting.autoSubtitles | Fetch subtitles automatically | Settings > Playback > Subtitles online | settings page Playback | Mac, iPhone, iPad | yes |
| setting.bestVersionFirst | Play the best version first | Settings > Playback > Behaviour | settings page Playback | Mac, iPhone, iPad | yes |
| setting.bufferingMode | Buffering mode | Settings > Playback > Buffering | settings page Playback | Mac, iPhone, iPad | yes |
| setting.castReading | Cast and directors | Settings > Library > Cast and directors | settings page Library | Mac, iPhone, iPad | yes |
| setting.catalogRefresh | Refresh playlists | Settings > Library > Catalog | settings page Library | Mac, iPhone, iPad | yes |
| setting.catchupClock | Catch-up provider's clock | Settings > Library > Manage > Playlists > Guide | modal playlists | Mac | yes |
| setting.clickBehavior | Open channels with | Settings > General > Browsing | settings page General | Mac, iPhone, iPad | yes |
| setting.collapseDuplicates | Group quality variants | Settings > General > Browsing | settings page General | Mac, iPhone, iPad | yes |
| setting.customTheme | Custom theme colours | Settings > Appearance > Theme | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.debrid | Debrid | Settings > Library > Debrid | settings page Library | Mac, iPhone, iPad | yes |
| setting.defaultAspect | Default aspect ratio | Settings > Playback > Video | settings page Playback | Mac | yes |
| setting.defaultChannelSort | Channel order | Settings > General > Browsing | settings page General | Mac, iPhone, iPad | yes |
| setting.defaultLibrarySort | Movies and series order | Settings > General > Browsing | settings page General | Mac, iPhone, iPad | yes |
| setting.defaultVideoSize | Default video size | Settings > Playback > Video | settings page Playback | Mac | yes |
| setting.deinterlace | Deinterlacing | Settings > Playback > Advanced video | settings page Playback | Mac, iPhone, iPad | yes |
| setting.density | Density | Settings > Appearance > Appearance | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.downloads | Downloads | Settings > Library > Downloads | settings page Library | Mac, iPhone, iPad | yes |
| setting.downloadsDeleteWatched | Delete a download after I have watched it | Settings > Library > Downloads | settings page Library | Mac, iPhone, iPad | yes |
| setting.downloadsWifiOnly | Downloads only on Wi-Fi | Downloads > Only on Wi-Fi | explained only | iPhone, iPad | yes |
| setting.engineForKind | Player engine for live, movies or past programmes | Settings > Playback > Player engine | settings page Playback | Mac, iPhone, iPad | yes |
| setting.enginePreference | Player engine | Settings > Playback > Player engine | settings page Playback | Mac, iPhone, iPad | yes |
| setting.guide.addXMLTV | Add a guide address | Settings > Library > Guide sources > Add | explained only | Mac, iPhone, iPad | yes |
| setting.guide.enrichLogos | Fill missing logos | Settings > Library > Guide sources > Fill missing logos, genres and countries | explained only | Mac, iPhone, iPad | yes |
| setting.guide.enrichmentEnabled | Use the public channel database | Settings > Guide > Public channel database | explained only | Mac, iPhone, iPad | no |
| setting.guide.freshness | Guide warnings | Settings > Library > Guide sources | explained only | Mac, iPhone, iPad | yes |
| setting.guide.publicDatabase | Public channel database | Settings > Library > Guide sources > Fill missing logos, genres and countries | explained only | Mac, iPhone, iPad | yes |
| setting.guide.reminderLeadMinutes | Remind me before | Settings > Guide > Reminders | explained only | Mac, iPhone, iPad | no |
| setting.guide.sources | Guide sources | Settings > Library > Guide sources | explained only | Mac, iPhone, iPad | yes |
| setting.guide.timeZoneMode | Guide time zone | Settings > Library > Playlists | explained only | Mac, iPhone, iPad | yes |
| setting.guideHoursVisible | Guide hours shown | TV Guide screen > Hours visible | explained only | Mac, iPhone, iPad | yes |
| setting.guideRefresh | Refresh the programme guide | Settings > Library > Programme guide | settings page Library | Mac, iPhone, iPad | yes |
| setting.guideRetentionDays | Keep past programmes | Settings > Library > Programme guide | settings page Library | Mac, iPhone, iPad | yes |
| setting.guideShift | Guide time shift | Settings > Library > Manage > Playlists > Guide | modal playlists | Mac | yes |
| setting.hardwareDecoding | Hardware decoding | Settings > Playback > Video | settings page Playback | Mac, iPhone, iPad | yes |
| setting.hideEmptyFolders | Hide empty folders | Settings > General > Browsing | settings page General | Mac, iPhone, iPad | yes |
| setting.highContrast | Increase contrast | Settings > Appearance > Appearance | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.icloudSync | iCloud sync | Settings > Library > iCloud | settings page Library | Mac, iPhone, iPad | yes |
| setting.integrations | Trakt, Debrid and AI | Settings > Library | settings page Library | Mac, iPhone, iPad | yes |
| setting.keywordAlerts | Guide alerts | Settings > Library > Guide alerts | settings page Library | Mac, iPhone, iPad | yes |
| setting.lanSync | Sync on this network | Settings > Library > Sync on this network | settings page Library | Mac, iPhone, iPad | yes |
| setting.language | App language | Settings > Appearance > Appearance | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.liveRewind | Pause and rewind live TV | Settings > Playback > Live TV | settings page Playback | Mac, iPhone, iPad | yes |
| setting.maintenance | Maintenance and reset | Settings > Library > Maintenance | settings page Library | Mac, iPhone, iPad | yes |
| setting.notificationPermission | Notification permission | Settings > General > Notifications | settings page General | Mac | yes |
| setting.opening | Opening | Settings > Appearance > Appearance | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.opensubtitlesKey | OpenSubtitles account and key | Settings > Playback > Subtitles online | settings page Playback | Mac, iPhone, iPad | yes |
| setting.parental | Parental controls and PIN | Settings > Privacy > Parental controls | settings page Privacy | Mac, iPhone, iPad | yes |
| setting.parentalPin | Parental PIN | Settings > Privacy > Parental controls | settings page Privacy | Mac, iPhone, iPad | yes |
| setting.parentalUnlock | Unlock lasts | Settings > Privacy > Parental controls | settings page Privacy | Mac, iPhone, iPad | yes |
| setting.picture | Picture adjustments | Settings > Playback > Advanced video > Picture | settings page Playback | Mac | yes |
| setting.playlistBuffering | Buffering for one playlist | Settings > Library > Manage > Playlists > Connection | modal playlists | Mac, iPhone, iPad | yes |
| setting.playlistEngine | Player engine for one playlist | Settings > Library > Manage > Playlists > Connection | modal playlists | Mac, iPhone, iPad | yes |
| setting.preferredAudioLanguage | Preferred audio language | Settings > Playback > Audio | settings page Playback | Mac, iPhone, iPad | yes |
| setting.preferredSubtitleLanguage | Preferred subtitle language | Settings > Playback > Subtitles | settings page Playback | Mac, iPhone, iPad | yes |
| setting.profiles | Profiles | Settings > Library > Profiles | settings page Library | Mac, iPhone, iPad | yes |
| setting.proxy | Proxy | Settings > Privacy > Proxy | settings page Privacy | Mac, iPhone, iPad | yes |
| setting.proxyHost | Proxy address | Settings > Privacy > Proxy | settings page Privacy | Mac, iPhone, iPad | yes |
| setting.proxyPort | Proxy port | Settings > Privacy > Proxy | settings page Privacy | Mac, iPhone, iPad | yes |
| setting.recordings | Recordings | Settings > Library > Recordings | settings page Library | Mac, iPhone, iPad | yes |
| setting.reduceMotion | Reduce animation | Settings > Appearance > Appearance | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.refreshOnOpen | Refresh when the app opens | Settings > Library > Catalog | settings page Library | Mac, iPhone, iPad | yes |
| setting.rememberFolders | Remember last folder | Settings > General > Browsing | settings page General | Mac, iPhone, iPad | yes |
| setting.rememberPerTitle | Remember settings for each title | Settings > Playback > Remembered choices | settings page Playback | Mac, iPhone, iPad | yes |
| setting.rememberPosition | Remember playback position | Settings > Playback > Behaviour | settings page Playback | Mac, iPhone, iPad | yes |
| setting.remindersEnabled | Programme reminders | Settings > General > Notifications | settings page General | Mac, iPhone, iPad | yes |
| setting.renderingProfile | Scaling quality | Settings > Playback > Advanced video | settings page Playback | Mac, iPhone, iPad | yes |
| setting.resumeAutomatically | Resume automatically | Settings > Playback > Behaviour | settings page Playback | Mac, iPhone, iPad | yes |
| setting.resumeLastChannel | Resume the last channel | Settings > General > At launch | settings page General | Mac, iPhone, iPad | yes |
| setting.scheduledRecordings | Scheduled recordings | Settings > Library > Recordings | settings page Library | Mac | yes |
| setting.showDiagnosticsOverlay | Show stream information | Settings > Playback > Troubleshooting | settings page Playback | Mac, iPhone, iPad | yes |
| setting.sidebarLaunch | Sidebar at launch | Settings > Appearance > Appearance | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.stereoDownmix | Downmix to stereo | Settings > Playback > Advanced audio | settings page Playback | Mac, iPhone, iPad | yes |
| setting.storage.guideBannerDismissed | Guide warning dismissed (guide.banner.dismissed) | Settings > Guide > Warnings | explained only | Mac, iPhone, iPad | no |
| setting.storage.ipadFoldersLive | Folder column in Live TV | Live TV > Folders | explained only | iPad | yes |
| setting.storage.liveChannelListCollapsed | Hide the channel list | Live TV > Toolbar > Hide channel list | explained only | Mac | yes |
| setting.storage.liveChannelListWidth | Width of the channel list | Live TV > Divider | explained only | Mac | yes |
| setting.storage.liveTVTiles | Channels as tiles or a list | Live TV > Show as list or tiles | explained only | iPhone, iPad | yes |
| setting.storage.playerControlSeconds | Hide controls after | Player > Options > Controls | explained only | iPhone, iPad | yes |
| setting.storage.playerFillScreen | Fit or fill the screen | Player > Options > Picture > Size | explained only | iPhone, iPad | yes |
| setting.storage.playerLeftHanded | Left-handed layout | Player > Options > Controls | explained only | iPhone, iPad | yes |
| setting.storage.playerStreamInfo | Stream details on the picture | Player > Options > Controls | explained only | iPhone, iPad | yes |
| setting.storage.playerTourSeen | Player quick tour | Player | explained only | iPhone, iPad | yes |
| setting.subscriptions | Subscriptions | Settings > Library > Subscriptions | settings page Library | Mac, iPhone, iPad | yes |
| setting.subtitleBackground | Subtitle background opacity | Settings > Playback > Subtitles | settings page Playback | Mac, iPhone, iPad | yes |
| setting.subtitleColor | Subtitle text colour | Settings > Playback > Subtitles | settings page Playback | Mac, iPhone, iPad | yes |
| setting.subtitleOutline | Subtitle outline and shadow | Settings > Playback > Subtitles | settings page Playback | Mac, iPhone, iPad | yes |
| setting.subtitlePosition | Subtitle vertical position | Settings > Playback > Subtitles | settings page Playback | Mac, iPhone, iPad | yes |
| setting.subtitleSize | Subtitle size | Settings > Playback > Subtitles | settings page Playback | Mac, iPhone, iPad | yes |
| setting.subtitlesByDefault | Show subtitles by default | Settings > Playback > Subtitles | settings page Playback | Mac, iPhone, iPad | yes |
| setting.syncLogins | Sync logins | Settings > Library > iCloud | settings page Library | Mac, iPhone, iPad | yes |
| setting.theme | Theme | Settings > Appearance > Theme | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.the movie database | the movie database key (artwork and details) | Settings > Library > Artwork and details | settings page Library | Mac, iPhone, iPad | yes |
| setting.tmdbKey | the movie database key | Settings > Library > Artwork and details | settings page Library | Mac, iPhone, iPad | yes |
| setting.toneMapping | HDR tone mapping | Settings > Playback > Advanced video | settings page Playback | Mac, iPhone, iPad | yes |
| setting.trakt | Trakt | Settings > Library > Trakt | settings page Library | Mac, iPhone, iPad | yes |
| setting.userAgent | User-Agent and headers for one playlist | Settings > Library > Manage > Playlists > Connection > Advanced connection | modal playlists | Mac, iPhone, iPad | yes |
| setting.videoQuality | Preferred quality | Settings > Playback > Video | settings page Playback | Mac, iPhone, iPad | yes |
| setting.volume | Volume | Player > Volume | explained only | Mac, iPhone, iPad | yes |
| setting.vpn | VPN | Settings > Privacy > VPN | settings page Privacy | Mac, iPhone, iPad | yes |

## Menu commands

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| menu.app.checkForUpdates | Check for Updates… | Menu bar > StreamSetu > Check for Updates… | explained only | Mac, direct download only | yes |
| menu.file.addPlaylist | Add Playlist… | Menu bar > File > Add Playlist… | modal addPlaylist | Mac | yes |
| menu.file.filesAndServers | Files and Servers… | Menu bar > File > Files and Servers… | window files | Mac | yes |
| menu.file.openVideoFile | Open Video File… | Menu bar > File > Open Video File… | explained only | Mac, iPhone, iPad | yes |
| menu.file.refreshAll | Refresh All Playlists | Menu bar > File > Refresh All Playlists | explained only | Mac | yes |
| menu.help.askSetu | Ask Setu | Menu bar > Help > Ask Setu | search askSetu | Mac | yes |
| menu.help.keyboardShortcuts | Keyboard Shortcuts | Menu bar > Help > Keyboard Shortcuts | window shortcuts | Mac | yes |
| menu.help.sendFeedback | Send Feedback… | Menu bar > Help > Send Feedback… | window feedback | Mac | yes |
| menu.navigate.home | Home | Menu bar > Navigate > Home | tab Home | Mac | yes |
| menu.navigate.liveTV | Live TV | Menu bar > Navigate > Live TV | tab Live TV | Mac | yes |
| menu.navigate.movies | Movies | Menu bar > Navigate > Movies | tab Movies | Mac | yes |
| menu.navigate.search | Search | Menu bar > Navigate > Search | search focus | Mac | yes |
| menu.navigate.searchThisScreen | Search in This Screen | Menu bar > Navigate > Search in This Screen | search focusScreen | Mac | yes |
| menu.navigate.series | Series | Menu bar > Navigate > Series | tab Series | Mac | yes |
| menu.navigate.services | Services | Menu bar > Navigate > Services | explained only | Mac | yes |
| menu.navigate.shuffle | Shuffle Recommendations | Menu bar > Navigate > Shuffle Recommendations | explained only | Mac | yes |
| menu.navigate.streamsetu | StreamSetu | Menu bar > Navigate > StreamSetu | explained only | Mac | yes |
| menu.navigate.tvGuide | TV Guide | Menu bar > Navigate > TV Guide | tab TV Guide | Mac | yes |
| menu.playback.lastChannel | Last Channel | Menu bar > Playback > Last Channel | explained only | Mac | yes |
| menu.playback.nextChannel | Next Channel | Menu bar > Playback > Next Channel | explained only | Mac | yes |
| menu.playback.nextEpisode | Next Episode | Menu bar > Playback > Next Episode | explained only | Mac | yes |
| menu.playback.openMultiView | Open Multi-View | Menu bar > Playback > Open Multi-View | window multiview | Mac | yes |
| menu.playback.openPlayerWindow | Open Player in New Window | Menu bar > Playback > Open Player in New Window | window player | Mac | yes |
| menu.playback.playPause | Play / Pause | Menu bar > Playback > Play / Pause | explained only | Mac | yes |
| menu.playback.previousChannel | Previous Channel | Menu bar > Playback > Previous Channel | explained only | Mac | yes |
| menu.playback.skipBack | Skip Back 10 Seconds | Menu bar > Playback > Skip Back 10 Seconds | explained only | Mac | yes |
| menu.playback.skipForward | Skip Forward 10 Seconds | Menu bar > Playback > Skip Forward 10 Seconds | explained only | Mac | yes |
| menu.playback.sleepTimer | Sleep Timer | Menu bar > Playback > Sleep Timer | explained only | Mac | yes |
| menu.playback.sleepTimerCancel | Cancel Sleep Timer | Menu bar > Playback > Cancel Sleep Timer | explained only | Mac | yes |
| menu.playback.sleepTimerEndOfItem | Stop at the End of This Episode or Movie | Menu bar > Playback > Stop at the End of This Episode or Movie | explained only | Mac | yes |
| menu.playback.stop | Stop | Menu bar > Playback > Stop | explained only | Mac | yes |
| menu.services.actualSize | Actual Size | Menu bar > Services > Actual Size | explained only | Mac | yes |
| menu.services.back | Back | Menu bar > Services > Back | explained only | Mac | yes |
| menu.services.clearData | Clear Data… | Menu bar > Services > Clear Data… | explained only | Mac | yes |
| menu.services.forward | Forward | Menu bar > Services > Forward | explained only | Mac | yes |
| menu.services.openInBrowser | Open in Default Browser | Menu bar > Services > Open in Default Browser | explained only | Mac | yes |
| menu.services.pin | Pin to Top Bar | Menu bar > Services > Pin to Top Bar | explained only | Mac | yes |
| menu.services.reload | Reload | Menu bar > Services > Reload | explained only | Mac | yes |
| menu.services.zoomIn | Zoom In | Menu bar > Services > Zoom In | explained only | Mac | yes |
| menu.services.zoomOut | Zoom Out | Menu bar > Services > Zoom Out | explained only | Mac | yes |

## Keyboard shortcuts

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| shortcut.dialog.escape | Esc closes a dialog | Keyboard > Dialogs | explained only | Mac | yes |
| shortcut.dialog.return | Return confirms the main button | Keyboard > Dialogs | explained only | Mac | yes |
| shortcut.folderRow.return | Folder rows: Return opens the folder | Keyboard > Movies and Series | explained only | Mac | yes |
| shortcut.global.escape | Esc closes the top layer | Keyboard > Anywhere | explained only | Mac | yes |
| shortcut.global.return | Return opens or plays | Keyboard > Anywhere | explained only | Mac | yes |
| shortcut.global.tab | Tab moves between controls | Keyboard > Anywhere | explained only | Mac | yes |
| shortcut.guide.arrows | TV Guide: move the time window | Keyboard > TV Guide | explained only | Mac | yes |
| shortcut.ipad.folders | iPad: ⌥⌘0 hides or shows the folder column | Keyboard > iPad | explained only | iPad | yes |
| shortcut.ipad.search | iPad: ⌘F opens Search | Keyboard > iPad | explained only | iPad | yes |
| shortcut.ipad.tabs | iPad: ⌘1 to ⌘9 open the sidebar destinations | Keyboard > iPad | explained only | iPad | yes |
| shortcut.liveTV.return | Live TV list: Return plays the channel | Keyboard > Live TV | explained only | Mac | yes |
| shortcut.multiView.escape | Multi-View: Esc restores the tiles | Keyboard > Multi-View | explained only | Mac | yes |
| shortcut.multiView.fill | Multi-View: fill the window | Keyboard > Multi-View | explained only | Mac | yes |
| shortcut.multiView.mute | Multi-View: mute | Keyboard > Multi-View | explained only | Mac | yes |
| shortcut.multiView.number | Multi-View: pick a tile with 1 to 4 | Keyboard > Multi-View | explained only | Mac | yes |
| shortcut.person.arrows | Person page: switch between all and your library | Keyboard > Person page | explained only | Mac | yes |
| shortcut.photos.keys | Photo viewer: arrows and Esc | Keyboard > Photo viewer | explained only | Mac | yes |
| shortcut.player.channelList | Open the channel list | Keyboard > Player | explained only | Mac | yes |
| shortcut.player.exitFullscreen | Esc leaves full screen | Keyboard > Player | explained only | Mac | yes |
| shortcut.player.fullscreen | Full screen | Keyboard > Player | explained only | Mac | yes |
| shortcut.player.mute | Mute | Keyboard > Player | explained only | Mac | yes |
| shortcut.player.numberEntry | Type a channel number | Keyboard > Player | explained only | Mac | yes |
| shortcut.player.pageKeys | Page Up and Page Down change channel | Keyboard > Player | explained only | Mac | yes |
| shortcut.player.seekArrows | Arrow keys skip 10 seconds | Keyboard > Player | explained only | Mac | yes |
| shortcut.player.seekJL | J and L skip 10 seconds | Keyboard > Player | explained only | Mac | yes |
| shortcut.player.space | Play or pause | Keyboard > Player | explained only | Mac | yes |
| shortcut.player.upDown | Up and down arrows in full screen | Keyboard > Player | explained only | Mac | yes |
| shortcut.search.down | Down arrow moves into the results | Keyboard > Search | explained only | Mac | yes |
| shortcut.search.escape | Esc clears the search | Keyboard > Search | explained only | Mac | yes |
| shortcut.search.results | Arrows and Return in search results | Keyboard > Search results | explained only | Mac | yes |
| shortcut.slideshow.keys | Featured banner: arrows and Space | Keyboard > Featured banner | explained only | Mac | yes |

## Context menus

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| context.channel.menu | Channel menu (right-click or press and hold) | Any channel > Context menu | explained only | Mac, iPhone, iPad | yes |
| context.commandCenter.channel | Channel Manager row menu | Channel Manager > Channel > Context menu | explained only | Mac | yes |
| context.files.source | Files source menu | Files and Servers > Source > Context menu | explained only | Mac | yes |
| context.guide.row | Guide programme menu | TV Guide > Programme > Context menu | explained only | Mac | yes |
| context.home.collectionChip | Collection menu | Home > Collections > Context menu | explained only | Mac | yes |
| context.home.collectionItem | Collection item menu | Home > Collections > Item > Context menu | explained only | Mac | yes |
| context.home.historyEntry | Watch History entry menu | Home > Watch History > Context menu | explained only | Mac | yes |
| context.home.recentChannel | Recently Watched channel menu | Home > Recently Watched > Context menu | explained only | Mac | yes |
| context.ios.episode | Episode menu (iPhone and iPad) | Series page > Episodes > Context menu | explained only | iPhone, iPad | yes |
| context.ios.liveChannel | Live TV channel menu (iPhone and iPad) | Live TV > Channel > Context menu | explained only | iPhone, iPad | yes |
| context.ios.multiViewTile | Multi-View tile menu (iPhone and iPad) | Multi-View > Tile > Context menu | explained only | iPhone, iPad | yes |
| context.ios.playlist | Playlist menu (iPhone and iPad) | More > Playlists > Playlist > Context menu | explained only | iPhone, iPad | yes |
| context.liveTV.channel | Live TV channel menu | Live TV > Channel > Context menu | explained only | Mac | yes |
| context.multiView.tileMac | Multi-View tile menu (Mac) | Multi-View > Tile > Context menu | explained only | Mac | yes |
| context.podcasts.show | Podcast menu | Files and Servers > Podcasts > Context menu | explained only | Mac | yes |
| context.search.result | Search result menu | Search results > Result > Context menu | explained only | Mac | yes |
| context.series.episode | Episode menu | Series page > Episode > Context menu | explained only | Mac | yes |
| context.series.seasonEpisode | Episode list menu | Series page > Episodes > Context menu | explained only | Mac | yes |
| context.sidebar.folderLock | Lock or unlock a folder | Sidebar > Folder > Context menu | explained only | Mac | yes |
| context.sidebar.folderReorder | Sidebar folder menu | Sidebar > Folder > Context menu | explained only | Mac | yes |
| context.slideshow.banner | Featured banner menu | Home > Discover > Banner > Context menu | explained only | Mac | yes |
| context.tile.addToQueue | Add to Queue | Any poster or channel > Context menu > Add to Queue | explained only | Mac, iPhone, iPad | yes |
| context.tile.collection | Add to Collection | Any poster or channel > Context menu > Add to Collection | explained only | Mac, iPhone, iPad | yes |
| context.tile.dontRecommend | Don't Recommend This | Any poster or channel > Context menu > Don't Recommend This | explained only | Mac, iPhone, iPad | yes |
| context.tile.favorite | Add to Favorites | Any poster or channel > Context menu > Add to Favorites | explained only | Mac, iPhone, iPad | yes |
| context.tile.goToCast | Go to Cast | Any poster or channel > Context menu > Go to Cast | explained only | Mac, iPhone, iPad | yes |
| context.tile.hide | Hide This Title | Any poster or channel > Context menu > Hide This Title | explained only | Mac, iPhone, iPad | yes |
| context.tile.hideChannel | Hide Channel | Any poster or channel > Context menu > Hide Channel | explained only | Mac, iPhone, iPad | yes |
| context.tile.menu | Poster menu (right-click or press and hold) | Any poster > Context menu | explained only | Mac, iPhone, iPad | yes |
| context.tile.moveToEnd | Move to End of Favorites | Any poster or channel > Context menu > Move to End of Favorites | explained only | Mac, iPhone, iPad | yes |
| context.tile.moveToFront | Move to Front of Favorites | Any poster or channel > Context menu > Move to Front of Favorites | explained only | Mac, iPhone, iPad | yes |
| context.tile.multiView | Add to Multi-View | Any poster or channel > Context menu > Add to Multi-View | explained only | Mac, iPhone, iPad | yes |
| context.tile.openDetails | View Details | Any poster or channel > Context menu > View Details | explained only | Mac, iPhone, iPad | yes |
| context.tile.openFolder | In folder | Any poster or channel > Context menu > In folder | explained only | Mac, iPhone, iPad | yes |
| context.tile.play | Play | Any poster or channel > Context menu > Play | explained only | Mac, iPhone, iPad | yes |
| context.tile.playNext | Play Next | Any poster or channel > Context menu > Play Next | explained only | Mac, iPhone, iPad | yes |
| context.tile.removeFromContinue | Remove from Continue Watching | Any poster or channel > Context menu > Remove from Continue Watching | explained only | Mac, iPhone, iPad | yes |
| context.tile.removeFromQueue | Remove from Queue | Any poster or channel > Context menu > Remove from Queue | explained only | Mac, iPhone, iPad | yes |
| context.tile.rename | Rename… | Any poster or channel > Context menu > Rename… | explained only | iPhone, iPad | yes |
| context.tile.resume | Resume | Any poster or channel > Context menu > Resume | explained only | Mac, iPhone, iPad | yes |
| context.tile.share | Share Link | Any poster or channel > Context menu > Share Link | explained only | Mac, iPhone, iPad | yes |
| context.tile.watchLater | Add to Watch Later | Any poster or channel > Context menu > Add to Watch Later | explained only | Mac, iPhone, iPad | yes |
| context.tile.watchPrivately | Watch Privately | Any poster or channel > Context menu > Watch Privately | explained only | Mac, iPhone, iPad | yes |

## Gestures and long presses

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| gesture.ios.guideDrag | Drag the TV Guide sideways | TV Guide | explained only | iPhone, iPad | yes |
| gesture.ios.multiViewTap | Multi-View: tap for sound, double-tap to fill | Multi-View > Tile | explained only | iPhone, iPad | yes |
| gesture.ios.playerBrightnessVolume | Drag at the sides for brightness and volume | Player | explained only | iPhone, iPad | yes |
| gesture.ios.playerEdges | Gestures ignore the screen edges | Player | explained only | iPhone, iPad | yes |
| gesture.ios.playerPinch | Pinch the video to fill or zoom | Player | explained only | iPhone, iPad | yes |
| gesture.ios.playerPullDown | Pull the top of the video down to close the player | Player | explained only | iPhone, iPad | yes |
| gesture.ios.playerScrub | Swipe along the video to move through a movie | Player | explained only | iPhone, iPad | yes |
| gesture.ios.playerSeekBar | Drag the seek bar | Player > Seek bar | explained only | iPhone, iPad | yes |
| gesture.ios.playerTap | Tap the video to show or hide the controls | Player | explained only | iPhone, iPad | yes |
| gesture.ios.playerZap | Swipe to change channel | Player > Live TV | explained only | iPhone, iPad | yes |
| gesture.ios.pullToRefresh | Pull down to refresh | iPhone > Home, Library, Live TV | explained only | iPhone, iPad | yes |
| gesture.ios.swipeActions | Swipe a row for its actions | iPhone > Lists | explained only | iPhone, iPad | yes |
| gesture.ios.swipeChannelManager | Swipe a channel in the Channel Manager: Hide or Show | Settings > Channel Manager > Channel row | explained only | iPhone, iPad | yes |
| gesture.ios.swipeCollection | Swipe a collection: Delete | More > Collections > Collection row | explained only | iPhone, iPad | yes |
| gesture.ios.swipeFavourite | Swipe a channel to favourite it | iPhone > Live TV > Channel row | explained only | iPhone | yes |
| gesture.ios.swipeFolderHide | Swipe a folder: Hide | Settings > Library > Folders > Folder row | explained only | iPhone, iPad | yes |
| gesture.ios.swipeHistory | Swipe a history line: Remove | More > Watch History > Line | explained only | iPhone, iPad | yes |
| gesture.ios.swipePeer | Swipe a paired device: Forget | Settings > Sync on this network > Devices | explained only | iPhone, iPad | yes |
| gesture.ios.swipePlaylist | Swipe a playlist: Delete or Refresh | More > Playlists > Playlist row | explained only | iPhone, iPad | yes |
| gesture.ios.tabBarPill | Bottom bar shrinks while you scroll | iPhone > Bottom tab bar | explained only | iPhone | yes |
| gesture.ios.tabRetap | Tap the current tab again | iPhone > Bottom tab bar | explained only | iPhone | yes |
| gesture.ios.tabTripleTap | Tap a tab three times | iPhone > Bottom tab bar | explained only | iPhone | yes |
| gesture.mac.channelListDivider | Drag the divider of the channel list | Live TV > Channel list | explained only | Mac | yes |
| gesture.mac.multiViewDoubleClick | Multi-View: click for sound, double-click to fill | Multi-View > Tile | explained only | Mac | yes |
| gesture.mac.photoPinch | Photo viewer: pinch to zoom, swipe to change photo | Files and Servers > Photo viewer | explained only | Mac | yes |
| gesture.mac.playerClick | Click the video to play or pause | Player | explained only | Mac | yes |
| gesture.mac.playerDoubleClick | Double-click the video for full screen | Player | explained only | Mac | yes |
| gesture.mac.playerHover | Move the mouse to show the controls | Player | explained only | Mac | yes |
| gesture.mac.playerPan | Drag a zoomed picture | Player | explained only | Mac | yes |
| gesture.mac.seekBarDrag | Drag on the seek bar | Player > Seek bar | explained only | Mac | yes |
| gesture.mac.sidebarDragFolders | Drag folders in the sidebar to reorder them | Sidebar > Folders | explained only | Mac | yes |
| gesture.mac.slideshowHover | Hover the banner to pause it | Home > Discover > Banner | explained only | Mac | yes |
| gesture.mac.windowDrop | Drop a file or link on the window | Any screen | explained only | Mac | yes |
| gesture.player.doubleTapSeek | Double-tap to skip 10 seconds | Player | explained only | iPhone, iPad | yes |
| gesture.player.hold | Press and hold for double speed | Player | explained only | iPhone, iPad | yes |

## Siri and Shortcuts

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| intent.askSetu | Ask Setu | Setu button | explained only | iPhone, iPad | yes |
| intent.nextChannel | Next Channel | Siri and Shortcuts | explained only | iPhone, iPad | yes |
| intent.pausePlayback | Pause StreamSetu | Siri and Shortcuts | explained only | iPhone, iPad | yes |
| intent.playChannel | Play a Channel | Siri and Shortcuts | explained only | iPhone, iPad | yes |
| intent.resumePlayback | Resume StreamSetu | Siri and Shortcuts | explained only | iPhone, iPad | yes |
| intent.sleepTimer | Set a Sleep Timer | Siri and Shortcuts | explained only | iPhone, iPad | yes |
| intent.stopPlayback | Stop StreamSetu | Siri and Shortcuts | explained only | iPhone, iPad | yes |

## How-tos

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| guide.addingAPlaylistOrSource | Adding a playlist or source | Help > Adding a playlist or source | explained only | Mac, iPhone, iPad | yes |
| guide.addingAnM3uLink | Adding an M3U link | Help > Adding an M3U link | explained only | Mac, iPhone, iPad | yes |
| guide.addingJellyfinOrEmby | Adding Jellyfin or Emby | Help > Adding Jellyfin or Emby | explained only | Mac, iPhone, iPad | yes |
| guide.addingPlex | Adding Plex | Help > Adding Plex | explained only | Mac, iPhone, iPad | yes |
| guide.addingStalkerOrHdhomerun | Adding Stalker or HDHomeRun | Help > Adding Stalker or HDHomeRun | explained only | Mac, iPhone, iPad | yes |
| guide.addingXtream | Adding Xtream | Help > Adding Xtream | explained only | Mac, iPhone, iPad | yes |
| guide.audio | Audio | Help > Audio | explained only | Mac, iPhone, iPad | yes |
| guide.backupAndSync | Backup and sync | Help > Backup and sync | explained only | Mac, iPhone, iPad | yes |
| guide.collections | Collections | Help > Collections | explained only | Mac, iPhone, iPad | yes |
| guide.continueWatchingAndHistory | Continue Watching and history | Help > Continue Watching and history | explained only | Mac, iPhone, iPad | yes |
| guide.favoritesAndWatchLater | Favorites and Watch Later | Help > Favorites and Watch Later | explained only | Mac, iPhone, iPad | yes |
| guide.guideProblems | Guide problems | Help > Guide problems | explained only | Mac, iPhone, iPad | yes |
| guide.keyboard | Keyboard | Help > Keyboard | explained only | Mac, iPhone, iPad | yes |
| guide.liveTvAndTheGuide | Live TV and the guide | Help > Live TV and the guide | explained only | Mac, iPhone, iPad | yes |
| guide.playbackProblems | Playback problems | Help > Playback problems | explained only | Mac, iPhone, iPad | yes |
| guide.playerEngines | Player engines | Help > Player engines | explained only | Mac, iPhone, iPad | yes |
| guide.playlists | Playlists | Help > Playlists | explained only | Mac, iPhone, iPad | yes |
| guide.privacyAndSafety | Privacy and safety | Help > Privacy and safety | explained only | Mac, iPhone, iPad | yes |
| guide.recordingAndDownloads | Recording and downloads | Help > Recording and downloads | explained only | Mac, iPhone, iPad | yes |
| guide.search | Search | Help > Search | explained only | Mac, iPhone, iPad | yes |
| guide.signInAndLoginProblems | Sign-in and login problems | Help > Sign-in and login problems | explained only | Mac, iPhone, iPad | yes |
| guide.subtitles | Subtitles | Help > Subtitles | explained only | Mac, iPhone, iPad | yes |
| guide.traktDebridAndAi | Trakt, Debrid and AI | Help > Trakt, Debrid and AI | explained only | Mac, iPhone, iPad | yes |
| guide.whereStreamsetuKeepsThings | Where StreamSetu keeps things | Help > Where StreamSetu keeps things | explained only | Mac, iPhone, iPad | yes |
| recipe.addEmby | Add an Emby server | Add Playlist | modal addPlaylist | Mac, iPhone, iPad | yes |
| recipe.addGuideAddress | Add a guide (XMLTV) address | Playlists > Edit > Guide address | modal playlists | Mac, iPhone, iPad | yes |
| recipe.addHDHomeRun | Add an HDHomeRun tuner | Add Playlist | modal addPlaylist | Mac, iPhone, iPad | yes |
| recipe.addJellyfin | Add a Jellyfin server | Add Playlist | modal addPlaylist | Mac, iPhone, iPad | yes |
| recipe.addM3U | Add an M3U link | Add Playlist | modal addPlaylist | Mac, iPhone, iPad | yes |
| recipe.addM3UFile | Add an M3U file from this device | Add Playlist | modal addPlaylist | Mac, iPhone, iPad | yes |
| recipe.addPlex | Add a Plex server | Add Playlist | modal addPlaylist | Mac, iPhone, iPad | yes |
| recipe.addStalker | Add a Stalker or MAG portal | Add Playlist | modal addPlaylist | Mac, iPhone, iPad, direct download only | yes |
| recipe.addXtream | Add an Xtream provider | Add Playlist | modal addPlaylist | Mac, iPhone, iPad | yes |
| recipe.airplayAndPip | Use AirPlay or Picture in Picture | Player | explained only | Mac, iPhone, iPad | yes |
| recipe.backupRestore | Back up and restore | Settings > Library > Backup | settings page Library | Mac, iPhone, iPad | yes |
| recipe.changeTheme | Change the theme or accent colour | Settings > Appearance | settings page Appearance | Mac, iPhone, iPad | yes |
| recipe.chooseAudioLanguage | Choose the audio language | Settings > Playback > Audio | settings page Playback | Mac, iPhone, iPad | yes |
| recipe.continueWatching | Pick up where you left off | Home > Continue Watching | sidebar continueWatching | Mac, iPhone, iPad | yes |
| recipe.download | Download for offline | Title page > Download | explained only | Mac, iPhone, iPad | yes |
| recipe.favoritesWatchLater | Save titles to Favorites or Watch Later | Home > Favorites | sidebar favorites | Mac, iPhone, iPad | yes |
| recipe.fixBuffering | Fix buffering | Playback | explained only | Mac, iPhone, iPad | yes |
| recipe.fixEmptyGuide | Fix an empty TV Guide | TV Guide | explained only | Mac, iPhone, iPad | yes |
| recipe.fixWrongArtwork | Fix wrong or missing posters | Settings > Library > Artwork and details | settings page Library | Mac, iPhone, iPad | yes |
| recipe.hideFolders | Hide or unhide a folder | Sidebar > Folder menu | explained only | Mac, iPhone, iPad | yes |
| recipe.icloudSync | Turn on iCloud sync | Settings > Library > iCloud | settings page Library | Mac, iPhone, iPad | yes |
| recipe.keyboardOnly | Use the app from the keyboard | Help > Keyboard Shortcuts | window shortcuts | Mac | yes |
| recipe.kidsProfile | Make a kids profile and lock a folder | Settings > Library > Profiles | settings page Library | Mac, iPhone, iPad | yes |
| recipe.lanSyncPair | Sync on your own network | Settings > Library > Sync on this network | settings page Library | Mac, iPhone, iPad | yes |
| recipe.makeCollection | Make a collection | Collections | sidebar collections | Mac, iPhone, iPad | yes |
| recipe.moveToNewDevice | Move to a new device | Settings > Library > Backup | settings page Library | Mac, iPhone, iPad | yes |
| recipe.multiView | Watch several channels at once | Playback > Open Multi-View | explained only | Mac, iPhone, iPad | yes |
| recipe.pasteAnyAddress | Paste any address and let the app work it out | Add Playlist | modal addPlaylist | Mac, iPhone, iPad | yes |
| recipe.record | Record a live channel | Player > Record this channel | explained only | Mac | yes |
| recipe.refreshPlaylist | Refresh a playlist | File > Refresh All Playlists | explained only | Mac, iPhone, iPad | yes |
| recipe.reorderChannels | Organise channels and folders | Channel Manager | modal channelManager | Mac, iPhone, iPad | yes |
| recipe.reportProblem | Report a problem | Help > Send Feedback… | window feedback | Mac, iPhone, iPad | yes |
| recipe.searchByActor | Search by actor or director | Settings > Library > Cast and directors | settings page Library | Mac, iPhone, iPad | yes |
| recipe.searchCommands | Type commands in the search box | Search | explained only | Mac, iPad | yes |
| recipe.setupSubtitles | Set up subtitles | Settings > Playback > Subtitles | settings page Playback | Mac, iPhone, iPad | yes |
| recipe.shiftGuideTimes | Fix guide times that are hours off | Playlists > Guide time shift | modal playlists | Mac, iPhone, iPad | yes |
| recipe.siriShortcuts | Use Siri and the Shortcuts app | Siri and Shortcuts | explained only | iPhone, iPad | yes |
| recipe.sleepTimer | Set a sleep timer | Playback > Sleep Timer | explained only | Mac, iPhone, iPad | yes |
| recipe.switchEngine | Switch the player engine | Settings > Playback > Player engine | settings page Playback | Mac, iPhone, iPad | yes |
| recipe.updateApp | Update the app | StreamSetu > Check for Updates… | explained only | Mac, direct download only | yes |
| recipe.watchPrivately | Watch without saving history | Title menu > Watch Privately | explained only | Mac, iPhone, iPad | yes |

## Troubleshooting

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| diag.artwork | Why posters are missing or wrong | Troubleshooting > Artwork | explained only | Mac, iPhone, iPad | yes |
| diag.blackScreen | Why the picture is black or frozen | Troubleshooting > Picture | explained only | Mac, iPhone, iPad | yes |
| diag.castSearch | Why a search by actor finds nothing | Troubleshooting > Search | explained only | Mac, iPhone, iPad | yes |
| diag.channelsEmpty | Why a playlist shows no channels | Troubleshooting > Playlists | explained only | Mac, iPhone, iPad | yes |
| diag.continueEmpty | Why Continue Watching is empty | Troubleshooting > Continue Watching | explained only | Mac, iPhone, iPad | yes |
| diag.downloads | Why a download will not start or has paused | Troubleshooting > Downloads | explained only | Mac, iPhone, iPad | yes |
| diag.engine | Which player engine to use | Troubleshooting > Player engine | explained only | Mac, iPhone, iPad | yes |
| diag.guide | Why the TV guide is empty or the times are wrong | Troubleshooting > TV Guide | explained only | Mac, iPhone, iPad | yes |
| diag.hdrWashed | Why HDR video looks dull or washed out | Troubleshooting > Picture | explained only | Mac | yes |
| diag.liveBehind | Why live TV is behind real time | Troubleshooting > Live TV | explained only | Mac, iPhone, iPad | yes |
| diag.lockedHidden | Why a folder or title has disappeared (locked folders) | Troubleshooting > Parental controls | explained only | Mac, iPhone, iPad | yes |
| diag.noPipAirplay | Why Picture in Picture or AirPlay is not available | Troubleshooting > Player engine | explained only | Mac, iPhone, iPad | yes |
| diag.noSound | Why there is no sound | Troubleshooting > Sound | explained only | Mac, iPhone, iPad | yes |
| diag.playback | Why a stream will not play or keeps buffering | Troubleshooting > Playback | explained only | Mac, iPhone, iPad | yes |
| diag.profileFavourites | Why favourites or history are missing | Troubleshooting > Profiles | explained only | Mac, iPhone, iPad | yes |
| diag.recording | Why a recording fails or did not happen | Troubleshooting > Recordings | explained only | Mac | yes |
| diag.reminders | Why programme reminders do not appear | Troubleshooting > Reminders | explained only | Mac, iPhone, iPad | yes |
| diag.searchEmpty | Why search finds nothing | Troubleshooting > Search | explained only | Mac, iPhone, iPad | yes |
| diag.source | Why a playlist will not load or its login is rejected | Troubleshooting > Playlists | explained only | Mac, iPhone, iPad | yes |
| diag.subtitlesMissing | Why subtitles do not show | Troubleshooting > Subtitles | explained only | Mac, iPhone, iPad | yes |
| diag.subtitlesOutOfSync | Why subtitles or sound are out of sync | Troubleshooting > Subtitles | explained only | Mac, iPhone, iPad | yes |
| diag.sync | Why sync between devices is not working | Troubleshooting > Sync | explained only | Mac, iPhone, iPad | yes |
| diag.vpnPause | Why playback stops when a VPN drops | Troubleshooting > VPN | explained only | Mac, iPhone, iPad | yes |

## About Setu and what is new

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| meta.canDoHere | What can I do here? | Setu | explained only | Mac, iPhone, iPad | yes |
| meta.privacySetu | What Setu sends and keeps | Setu > Privacy | explained only | Mac, iPhone, iPad | yes |
| meta.whatsNew | What's new | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.2026.11.02 | New on Fire TV and Android in November | About > What's new | explained only | none | yes |
| meta.whatsNew.2026.11.07 | New in Mac 2.16.0 | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.2026.11.21 | New in Mac 2.17.0 and iPhone 1.3 | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.next.1 | Coming: Title pages | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.next.10 | Coming: The Setu assistant is on | About > What's new | modal about | iPhone, iPad | yes |
| meta.whatsNew.next.11 | Coming: Setu upgrade | About > What's new | modal about | iPhone, iPad | yes |
| meta.whatsNew.next.2 | Coming: Genre shelves | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.next.3 | Coming: Stars on every tile | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.next.4 | Coming: Better matching of titles to artwork and details | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.next.5 | Coming: More artwork and details from four sources | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.next.6 | Coming: the movie database works out of the box | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.next.7 | Coming: Privacy Policy and credits updated | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.next.8 | Coming: Search fixes | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.next.9 | Coming: Speed work | About > What's new | modal about | Mac, iPhone, iPad | yes |

---

# What Setu can do for you (actions)

Generated from the code by the coverage tests. **Reported, pending independent verification.** Verification means automated tests on macOS only: iPhone/iPad code compiles but is not run, and Android and Fire TV have none of this.

Columns: *UI* = the app has its own control · *Read* = how the assistant looks at it · *Act* = what it can offer (always tap-to-confirm, rechecked by the authorizer) · *Restrictions tested* · *Error path tested* · *Platforms verified*.

**175 rows: 138 covered, 37 unsupported with a reason.**


### agent action

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| diagnostics.copyReport | same service: DiagnosticsService.report (secrets removed) | — | read, scope device, inputs: none, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| guide.sync | same service: AppState.syncAll | — | control, scope device, inputs: none, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| library.favourite | same service: AppState.toggleFavorite | — | libraryChange, scope profile, inputs: title: library item, on: bool, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| library.favourite | same service: AppState.toggleFavorite | — | libraryChange, scope profile, inputs: id: library item, on: bool, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| library.play | same service: PlayActions / PlaybackCoordinator.play | — | control, scope session, inputs: title: library item, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| library.play | same service: PlayActions / PlaybackCoordinator.play | — | control, scope session, inputs: id: library item or channel, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| library.resume | same service: HistoryRepository.continueWatching + PlaybackCoordinator.play | — | control, scope profile, inputs: none, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| library.watchLater | same service: AppState.toggleWatchLater | — | libraryChange, scope profile, inputs: title: library item, on: bool, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| live.lastChannel | same service: AppSettings.lastChannelID + PlaybackCoordinator.play | — | control, scope profile, inputs: none, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| navigation.open | same service: AppRouter.navigate / SearchCommandRunner | — | control, scope session, inputs: target: screen, filter: text?, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| navigation.openAtlas | same service: AtlasOpener (the same router calls the buttons use) | — | control, scope session, inputs: id: atlas entry with a way to open it, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| player.control | same service: PlaybackCoordinator | — | control, scope session, inputs: action: pause|play|mute|unmute|volume_up|volume_down|forward|back|next_episode|stop, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| player.engine | same service: PlaybackCoordinator.switchEngine / AppSettings.enginePreference | — | control, scope session, inputs: engine: mpv|avPlayer|auto, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| player.retry | same service: PlaybackCoordinator.retryNow | — | control, scope session, inputs: none, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| player.track | same service: PlaybackCoordinator.selectAudio / selectSubtitle | — | control, scope session, inputs: kind: audio|subtitle, track: available track, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| playlists.refresh | same service: AppState.syncAll | — | control, scope device, inputs: none, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| settings.change | same service: AppSettings (same properties the Settings screens bind to) | — | preference, scope profile, inputs: id: catalogue setting, value: allowed option, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |

### agent tool

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| change_setting | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| check_library | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| control_playback | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| diagnose_playback | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| favourite | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| find_help | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| find_setting | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| guide_status | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| now_playing | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| open_screen | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| play_title | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| problem_report | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| recommend_engine | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| refresh_playlists | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| resume_watching | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| retry_playback | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| search_everything | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| search_library | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| select_track | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| similar_titles | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| source_health | n/a | read (sends no login) | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| source_setup_help | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| switch_engine | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| sync_guide | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| title_details | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| tv_guide | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| watch_later | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| watch_stats | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| web_lookup | n/a | read (sends only the topic to Wikipedia) | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| web_titles | n/a | read (sends only the person or franchise name to Wikipedia) | — | n/a (read only) | yes | macOS · iOS compiled, not run |

### context menu

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| DesignSystem/Components/Cards/FeaturedSlideshow.swift | yes | — | — | — | — | **Unsupported:** Featured banner menu: the shared title menu (same as the tiles); partly reachable as favourite, watch_later and play_title. |
| DesignSystem/Components/Sidebar/ReddySidebar.swift | yes | — | — | — | — | **Unsupported:** Sidebar folder menu (lock, hide, rename): not mapped yet. |
| Features/CommandCenter/Views/CommandCenterView.swift | yes | — | — | — | — | **Unsupported:** Channel and folder manager menus: not mapped yet. |
| Features/Files/FilesView.swift | yes | — | — | — | — | **Unsupported:** Local file menu: not mapped yet. |
| Features/Files/PodcastsView.swift | yes | — | — | — | — | **Unsupported:** Podcast menu: not mapped yet. |
| Features/Home/Views/HomeScreen.swift | yes | — | — | — | — | **Unsupported:** Title card menu (favourite, watch later, hide): reachable as the favourite and watch_later tools, not as its own entry. |
| Features/LiveTV/Views/LiveTVScreen.swift | yes | — | — | — | — | **Unsupported:** Channel menu (favourite, reminders, versions): partly reachable as favourite and play_title. |
| Features/Player/Views/MultiViewWindow.swift | yes | — | — | — | — | **Unsupported:** Multi-view tile menu: not mapped yet. |
| Features/Series/Views/EpisodeCard.swift | yes | — | — | — | — | **Unsupported:** Episode menu (play, watch privately, mark watched, reset progress): declared in the Atlas as the episode menu; not an assistant action yet. |
| Features/Shared/TileMenu.swift | yes | — | — | — | — | **Unsupported:** Title menu on every tile (one shared builder): partly reachable as favourite, watch_later and play_title. |
| Features/Streaming/PinnedServicesBar.swift | yes | — | — | — | — | **Unsupported:** Service pill menu (reload, pin or unpin, move left or right, clear data): control.services.pillmenu. |
| Features/Streaming/ServicesDropdown.swift | yes | — | — | — | — | **Unsupported:** Services list row menu (move up or down for a pinned service): control.services.move. |
| Features/TVGuide/Components/GuideRow.swift | yes | — | — | — | — | **Unsupported:** Programme menu (remind, record): not mapped yet. |

### feature

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| Collections | yes | — | — | — | — | **Unsupported:** Not mapped yet: no read or create/add tools (planned: read, then previewed changes). |
| CommandCenter | yes | — | — | — | — | **Unsupported:** Channel Manager, folders and sidebar management are not mapped yet (planned). |
| ContinueWatching | yes | context screen name | resume_watching | yes: AssistantAuthorizer | yes: nothing to resume | macOS · iOS compiled, not run |
| Favorites | yes | context screen name | favourite (add/remove) | yes: AssistantAuthorizer (profile, locked folders) | yes: title not in library | macOS · iOS compiled, not run |
| Files | yes | — | — | — | — | **Unsupported:** Local files, podcasts and 'On Your Device' are not mapped yet. |
| Home | yes | screen name, search text | open_screen, search_everything | n/a | yes | macOS · iOS compiled, not run |
| LiveTV | yes | search_everything, tv_guide, now_playing | play_title, open_screen | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| Movies | yes | search_library, title_details, similar_titles | play_title, favourite, watch_later, open_screen with filters | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| the external service | yes | — | — | — | — | **Unsupported:** One of the outside websites (streaming services) shown in a web view (Mac only), with the Services menu and pinned items in the top bar. Setu does not read or control any of them: nothing is injected into the page, and sign-in, cookies and playback stay between the person and the website. |
| Onboarding | yes | — | — | — | — | **Unsupported:** First-run screens; the assistant is not shown there. |
| Opening | yes | — | — | — | — | **Unsupported:** The opening and What's New at launch; the assistant is not shown there. |
| Player | yes | diagnose_playback, now_playing, recommend_engine | control_playback, retry_playback, switch_engine, select_track | yes: AssistantAuthorizer (session, profile) | yes: diagnosis table | macOS · iOS compiled, not run |
| RecentlyWatched | yes | — | — | — | — | **Unsupported:** History is summarised by watch_stats but not searchable or editable by the assistant yet. |
| Search | yes | search_everything (same engine as the search box) | open_screen with filter words | n/a | yes | macOS · iOS compiled, not run |
| Series | yes | search_everything, title_details, similar_titles | play_title, favourite, watch_later | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| Settings | yes | find_setting, find_help | change_setting (catalogued settings only) | yes: AssistantAuthorizer | yes: invalid and unchangeable settings | macOS · iOS compiled, not run |
| Shared | n/a | — | — | — | — | **Unsupported:** Shared building blocks, not a feature. |
| Sources | yes | source_health, guide_status, source_setup_help | refresh_playlists (offered) | yes: AssistantAuthorizer; credentials never read | yes | macOS · iOS compiled, not run |
| Streaming | yes | — | — | — | — | **Unsupported:** One of the outside websites (streaming services) shown in a web view (Mac only), with the Services menu and pinned items in the top bar. Setu does not read or control any of them: nothing is injected into the page, and sign-in, cookies and playback stay between the person and the website. |
| TVGuide | yes | tv_guide, guide_status | sync_guide (offered) | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |

### modal

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| about | yes | — | — | — | — | **Unsupported:** Nothing for the assistant to read or do. |
| addPlaylist | yes | how-to via source_setup_help; never reads or stores credentials | explains the fields only | n/a (credentials go through the normal form into the Keychain) | no | macOS · iOS compiled, not run |
| channelManager | yes | — | — | — | — | **Unsupported:** Channel and folder management is not mapped to the registry yet (planned: read-only inspection first, then previewed changes). |
| playlists | yes | sanitized status via source_health | refresh_playlists (offered), open_screen(settings) | yes: AssistantAuthorizer (profile, freshness) | yes: source_health failures | macOS · iOS compiled, not run |
| unlockRestricted | yes | — | — | — | — | **Unsupported:** By design: PINs are entered only in the normal secure form; the assistant never unlocks anything. |

### setting

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| accent | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| appDNS | yes | find_setting (explains it) | none by design (security, accounts, sync or network) | yes: refused | yes | macOS · iOS compiled, not run |
| appLock | yes | find_setting (explains it) | none by design (security, accounts, sync or network) | yes: refused | yes | macOS · iOS compiled, not run |
| audioOutputUID | yes | — | — | — | — | **Unsupported:** Needs the list of this Mac's output devices, which the assistant cannot read yet. macOS only. |
| audioProcessing | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · needs MPV |
| autoBackup | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| autoPlayNextEpisode | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| autoSubtitles | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| bestVersionFirst | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| bufferingMode | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| catalogRefresh | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| clickBehavior | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| collapseDuplicates | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| customTheme | yes | — | — | — | — | **Unsupported:** A colour set made in the theme editor. The assistant can pick a named theme but not edit custom colours. |
| defaultChannelSort | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| defaultLibrarySort | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| deinterlace | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · needs MPV |
| density | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| enginePreference | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| guideHoursVisible | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| guideRefresh | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| guideRetentionDays | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| hardwareDecoding | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| hideEmptyFolders | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| highContrast | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| iCloudSync | yes | find_setting (explains it) | none by design (security, accounts, sync or network) | yes: refused | yes | macOS · iOS compiled, not run |
| lanSync | yes | find_setting (explains it) | none by design (security, accounts, sync or network) | yes: refused | yes | macOS · iOS compiled, not run |
| language | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| lastAutoBackup | yes | — | — | — | — | **Unsupported:** A timestamp the backup writes, not a preference. |
| lastChannelID | yes | — | — | — | — | **Unsupported:** A record of the last channel played, not a preference. |
| liveRewind | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · needs MPV |
| picture | yes | — | — | — | — | **Unsupported:** Brightness, contrast, saturation, gamma and hue are adjusted from the player's picture button, per stream. |
| preferredAudioLanguage | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| preferredSubtitleLanguage | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| proxyHost | yes | find_setting (explains it) | none by design (security, accounts, sync or network) | yes: refused | yes | macOS · iOS compiled, not run |
| proxyKind | yes | find_setting (explains it) | none by design (security, accounts, sync or network) | yes: refused | yes | macOS · iOS compiled, not run |
| proxyPort | yes | find_setting (explains it) | none by design (security, accounts, sync or network) | yes: refused | yes | macOS · iOS compiled, not run |
| reduceMotion | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| refreshOnOpen | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| rememberFolders | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| rememberPosition | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| remindersEnabled | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| renderingProfile | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · needs MPV |
| resumeAutomatically | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| resumeLastChannel | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| showDiagnosticsOverlay | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| sidebarLaunch | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| sidebarWasCollapsed | yes | — | — | — | — | **Unsupported:** State the sidebar records for itself, not a preference anyone sets. |
| stereoDownmix | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · needs MPV |
| subtitleBackground | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| subtitleColor | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| subtitleOutline | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · needs MPV |
| subtitlePosition | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · needs MPV (not shown by the Apple engine) |
| subtitleSize | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| subtitlesByDefault | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| syncLogins | yes | find_setting (explains it) | none by design (security, accounts, sync or network) | yes: refused | yes | macOS · iOS compiled, not run |
| theme | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| toneMapping | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · needs MPV |
| videoQuality | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
| volume | yes | — | — | — | — | **Unsupported:** Player volume is a session control: the assistant offers volume up, down and mute through player.control, not a stored setting. |
| vpnPause | yes | find_setting (explains it) | none by design (security, accounts, sync or network) | yes: refused | yes | macOS · iOS compiled, not run |

### settings tab

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| advanced | yes | find_setting covers: Advanced (explain only: diagnostics, reset) | none by design | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| appearance | yes | find_setting covers: Appearance | change_setting for catalogued settings | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| general | yes | find_setting covers: General | change_setting for catalogued settings | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| library | yes | find_setting covers: Library | change_setting for catalogued settings | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| playback | yes | find_setting covers: Playback | change_setting for catalogued settings | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| privacy | yes | find_setting covers: Privacy (explain only: lock, proxy, VPN, parental) | none by design | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |

### sidebar shortcut

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| addedThisMonth | yes | — | — | — | — | **Unsupported:** No destination in open_screen yet. |
| allChannels | yes | screen name | open_screen(liveTV) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| allMovies | yes | screen name | open_screen(movies) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| collections | yes | screen name | open_screen(collections) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| continueWatching | yes | screen name | open_screen(continueWatching), resume_watching | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| discover | yes | screen name | open_screen(discover) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| favorites | yes | screen name | open_screen(favorites), favourite | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| featured | yes | — | — | — | — | **Unsupported:** No destination in open_screen yet. |
| library | yes | screen name | open_screen(series) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| newEpisodes | yes | — | — | — | — | **Unsupported:** No destination in open_screen yet. |
| recentlyAdded | yes | — | — | — | — | **Unsupported:** Reachable by typing 'newest' as a Movies/Series filter, but not as its own destination. |
| recentlyWatched | yes | screen name | open_screen(recentlyWatched) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| statistics | yes | screen name; totals via watch_stats | open_screen(statistics) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| tonight | yes | screen name | open_screen(tonight) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| unwatched | yes | screen name | open_screen(movies, filter: unwatched) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| unwatchedFavorites | yes | — | — | — | — | **Unsupported:** No destination in open_screen yet. |
| watchHistory | yes | screen name; viewing totals via watch_stats | open_screen(history) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| watchLater | yes | screen name | open_screen(watchLater), watch_later | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |

### tab

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| guide | yes | screen name; programmes via tv_guide, guide_status | open_screen, sync_guide | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| home | yes | screen name in context | open_screen | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| liveTV | yes | screen name in context; channels via search_everything, tv_guide | open_screen, play_title | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| movies | yes | screen name; titles via search_library, title_details | open_screen with filter words, play_title | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| series | yes | screen name; titles via search_everything, title_details, similar_titles | open_screen with filter words, play_title | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
