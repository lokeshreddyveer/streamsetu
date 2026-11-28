# Assistant coverage

Generated from the atlas by `AtlasCoverageTests` (set `ATLAS_DOCS_WRITE=1` to rewrite it). Everything Setu can answer about the app is one entry in `macos/Sources/REDDY/Atlas`; this page lists them all. *Reviewed* means the wording was checked against the code by a person or in a test; the rest was written from the code and has not had a second look. Setu answers from these entries with no language model.

## Totals

| Kind | Entries | Reviewed | Mac | iPhone | iPad |
|---|---|---|---|---|---|
| Screens | 163 | 142 | 120 | 46 | 45 |
| Settings pages | 24 | 24 | 6 | 18 | 18 |
| Controls and settings groups | 1748 | 631 | 1544 | 235 | 235 |
| Settings | 151 | 151 | 143 | 89 | 90 |
| Menu commands | 47 | 47 | 47 | 1 | 1 |
| Keyboard shortcuts | 54 | 54 | 51 | 0 | 3 |
| Context menus | 44 | 44 | 39 | 27 | 27 |
| Gestures and long presses | 35 | 35 | 11 | 24 | 20 |
| Siri and Shortcuts | 8 | 8 | 0 | 8 | 8 |
| How-tos | 78 | 78 | 77 | 60 | 62 |
| Troubleshooting | 39 | 39 | 39 | 25 | 25 |
| About Setu and what is new | 23 | 23 | 20 | 18 | 18 |
| **All** | **2414** | **1276** | 2097 | 551 | 552 |

Entries Setu explains but never changes (app lock, proxy, parental controls and similar): 57.

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
| screen.destination.music | Music | Music | destination music | Mac | yes |
| screen.destination.playlists | Go to Playlists | Playlists | destination playlists | Mac | yes |
| screen.destination.podcasts | Podcasts | Podcasts | destination podcasts | Mac | no |
| screen.destination.series | Go to Series | Series > Library | destination series | Mac | yes |
| screen.downloads | Downloads | Settings > Library > Downloads | search downloads | Mac | yes |
| screen.feedback | Send Feedback | Help > Send Feedback | window feedback | Mac | yes |
| screen.filesAndServers | Files and Servers | File > Files and Servers | window files | Mac | yes |
| screen.folderRows | Folder rows | Movies or Series > Folders view | explained only | Mac | yes |
| screen.guide.grid | Guide grid | TV Guide > Grid | tab TV Guide | Mac | yes |
| screen.home.offline | Offline Home | Home | tab Home | Mac, iPhone, iPad | yes |
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
| screen.music.actor | Music with an actor | Music > Actor | destination music | Mac | no |
| screen.music.alternatives | Choose another audio source | Music > Player > Choose another audio source | destination music | Mac | no |
| screen.music.blacklist | Never Play List | Music > Settings > Never Play List | destination music | Mac | no |
| screen.music.collection | Music Collection | Music > Explore > Collection | destination music | Mac | no |
| screen.music.devices | Music Devices | Music > Devices | destination music | Mac | yes |
| screen.music.downloads | Music Downloads | Music > Downloads | destination music | Mac | yes |
| screen.music.entity | Music Song, Album, Person or Film Page | Music > Page | destination music | Mac | no |
| screen.music.explore | Music Explore | Music > Explore | destination music | Mac | yes |
| screen.music.exploreRegion | Explore | Music > Explore | destination music | Mac | yes |
| screen.music.facet | Language, era, region or genre page | Music > Explore > Languages and eras | destination music | Mac | no |
| screen.music.film | Film page | Music > Film | destination music | Mac | no |
| screen.music.home | Music Listen Now | Music > Listen Now | destination music | Mac | yes |
| screen.music.import | Import to Music | Music > Your Library > Import | destination music | Mac | no |
| screen.music.karaoke | Karaoke settings | Music > Settings > Playback > Karaoke | destination music | Mac | no |
| screen.music.library | Your Music Library | Music > Your Library | destination music | Mac | yes |
| screen.music.libraryTabs | Library tabs | Music > Your Library | destination music | Mac | yes |
| screen.music.listenNowPersonal | Listen Now, your personal page | Music > Listen Now | destination music | Mac | yes |
| screen.music.lyricsEditor | Lyrics editor | Music > Player > Lyrics editor | destination music | Mac | no |
| screen.music.miniPlayerWindow | Mini player | Music > Player bar > Mini player | destination music | Mac | yes |
| screen.music.palette | Music quick search | Music > Quick search | destination music | Mac | no |
| screen.music.person | Music person page | Music > Person | destination music | Mac | yes |
| screen.music.player | Music Now Playing | Music > Player | destination music | Mac | yes |
| screen.music.radio | Music Radio | Music > Radio | destination music | Mac | yes |
| screen.music.recentlyAdded | Music Recently Added | Music > Recently Added | destination music | Mac | no |
| screen.music.room | Listen Together | Music > Listen Together | destination music | Mac | yes |
| screen.music.search | Music Search | Music > Search | destination music | Mac | yes |
| screen.music.settings | Music Settings | Music > Settings | destination music | Mac | yes |
| screen.music.settingsMap | Music settings: which tab holds what | Music > Settings | destination music | Mac | yes |
| screen.music.setup | Set up Music | Music > Set up | destination music | Mac | no |
| screen.music.shortcutsList | Music keyboard shortcuts list | Music | destination music | Mac | yes |
| screen.music.sidePanel | Music side panel tabs | Music > Side panel | destination music | Mac | yes |
| screen.music.sidebarLibrary | Library group in the Music sidebar | Music > Sidebar > Library | destination music | Mac | yes |
| screen.music.sidebarPlaylists | Playlists group in the Music sidebar | Music > Sidebar > Playlists | destination music | Mac | yes |
| screen.music.smartPlaylist | Smart playlist | Music > Your library > Playlists > Made for you | destination music | Mac | no |
| screen.music.song | Music Song Page | Music > Page | destination music | Mac | no |
| screen.music.soundtrack | Music Album and Soundtrack Page | Music > Album | destination music | Mac | no |
| screen.music.sources | Audio sources | Music > Settings > Plugins & Sources > Added sources | destination music | Mac | yes |
| screen.music.stats | Music statistics | Statistics > Music | destination music | Mac | no |
| screen.music.theatre | Theatre mode | Music > Player | destination music | Mac | yes |
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
| screen.settings.backup | Backup and Restore | Settings > Backup and Restore | settings page backup | iPhone, iPad | yes |
| screen.settings.general | General settings | Settings > General | settings page General | Mac | yes |
| screen.settings.library | Library settings | Settings > Library | settings page Library | Mac | yes |
| screen.settings.playback | Playback settings | Settings > Playback | settings page Playback | Mac | yes |
| screen.settings.privacy | Privacy settings | Settings > Privacy | settings page Privacy | Mac | yes |
| screen.settings.storage | Storage and Maintenance | Settings > Storage and Maintenance | settings page storage | iPhone, iPad | yes |

## Controls and settings groups

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| control.addSource.helpMeWithThis | Help me with this (Add Playlist) | Add Playlist > Help me with this | explained only | Mac | yes |
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
| control.enhancement.promptHideAds | Hide ads and upgrade prompts (first-open card) | Services | explained only | Mac | no |
| control.enhancement.promptMuteAds | Mute audio ads (first-open card) | Services | explained only | Mac | no |
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
| control.guide.removeGuide | Add or remove a guide, Guide name | Settings > Library > Guide sources | settings page Library | Mac, iPhone, iPad | yes |
| control.home.clearContinue | Clear Continue Watching, Recently Watched or Everything | Home > Continue Watching | explained only | Mac, iPhone, iPad | yes |
| control.home.clearMenu | Clear menu | Home | explained only | Mac | yes |
| control.home.collection | Collection | Home > Discover | explained only | Mac, iPhone, iPad | no |
| control.home.collectionDone | Close collection | Home > Discover | explained only | Mac | no |
| control.home.discoverClear | Clear Discover filters | Home > Discover | explained only | Mac | yes |
| control.home.discoverLanguage | Discover language filter | Home > Discover | explained only | Mac | yes |
| control.home.discoverOrder | Discover order | Home > Discover | explained only | Mac | yes |
| control.home.genre | Browse by genre | Home > Discover | explained only | Mac | yes |
| control.home.nowPlayingElsewhere | Play here | Home | explained only | Mac | yes |
| control.home.shelfMode | Shelf mode | Home | explained only | Mac, iPhone, iPad | yes |
| control.integrations.traktSignIn | Sign in to Trakt, Save Keys, Remove Keys, Save Token | Settings > Library > Trakt | settings page Library | Mac, iPhone, iPad | yes |
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
| control.ios.ipad.searchShortcut | Open Search with the keyboard | iPad > Sidebar > Search shortcut | explained only | iPhone, iPad | yes |
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
| control.music.account | Music account menu | Music > Sidebar > Account | explained only | Mac | yes |
| control.music.accountsAddAccount | Add account | Music > Accounts | explained only | Mac | yes |
| control.music.accountsAddAnotherGoogleAccount | Add another Google account | Music > Accounts | explained only | Mac | yes |
| control.music.accountsCancel | Cancel | Music > Accounts | explained only | Mac | yes |
| control.music.accountsCancelSignIn | Cancel sign in | Music > Accounts | explained only | Mac | yes |
| control.music.accountsChooseAChannel | Choose a channel | Music > Accounts | explained only | Mac | yes |
| control.music.accountsClose | Close | Music > Accounts | explained only | Mac | yes |
| control.music.accountsCurrentChannel | Current channel | Music > Accounts | explained only | Mac | yes |
| control.music.accountsInneraccountrowButton | An account row | Music > Sidebar > Account | explained only | Mac | yes |
| control.music.accountsInnerbodyButton | Account menu item | Music > Sidebar > Account | explained only | Mac | yes |
| control.music.accountsOk | OK | Music > Accounts | explained only | Mac | yes |
| control.music.accountsRemove | Remove | Music > Accounts | explained only | Mac | yes |
| control.music.accountsRemoveAccount | Remove account | Music > Accounts | explained only | Mac | yes |
| control.music.accountsSignInToYoutubeMusicWith | Sign in to the external service Music with Google | Music > Accounts | explained only | Mac | yes |
| control.music.accountsSignInWithGoogle | Sign in with Google | Music > Accounts | explained only | Mac | yes |
| control.music.accountsSignOut | Sign out | Music > Accounts | explained only | Mac | yes |
| control.music.accountsSignOutOfYoutubeMusic | Sign out of the external service Music | Music > Accounts | explained only | Mac | yes |
| control.music.accountsSwitch | Switch | Music > Accounts | explained only | Mac | yes |
| control.music.accountsSwitchChannel | Switch channel | Music > Accounts | explained only | Mac | yes |
| control.music.accountsSwitchTo | Switch to | Music > Accounts | explained only | Mac | yes |
| control.music.accountsSwitchYoutubeChannel | Switch the external service channel | Music > Accounts | explained only | Mac | yes |
| control.music.accountsTryLoadingTheChannelsAgain | Try loading the channels again | Music > Accounts | explained only | Mac | yes |
| control.music.accountsTrySigningInAgain | Try signing in again | Music > Accounts | explained only | Mac | yes |
| control.music.acoustidCancel | Cancel connection | Music > Menus | explained only | Mac | no |
| control.music.acoustidConnect | Connect AcoustID | Music > Menus | explained only | Mac | no |
| control.music.acoustidConnectClose | Close | Music > Menus | explained only | Mac | no |
| control.music.acoustidCopyCode | Copy code | Music > Menus | explained only | Mac | no |
| control.music.acoustidDisconnect | Disconnect | Music > Menus | explained only | Mac | no |
| control.music.acoustidOpen | Open approval page | Music > Menus | explained only | Mac | no |
| control.music.acoustidRetry | Try connecting again | Music > Menus | explained only | Mac | no |
| control.music.addToPlaylist | Add to playlist | Music > Menu | explained only | Mac | no |
| control.music.albumAddToPlaylist | Add the album to a playlist | Music > Album | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesAddToPlaylist | Add to Playlist | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesAddToQueue | Add to Queue | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesBack | Back | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesCancel | Cancel | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesDeletePlaylist | Delete Playlist | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesEditPlaylist | Edit Playlist | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesLoadMore | Load more | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesPlayAll | Play all | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesPlayNext | Play Next | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesSaveACopyToYourLibrary | Save a copy to Your library as a playlist | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesShare | Share | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesShuffleAll | Shuffle all | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtistAndPlaylistPagesStartRadio | Start Radio | Music > Album > artist and playlist pages | explained only | Mac | no |
| control.music.albumArtworkNext | Next album picture | Music > Album | explained only | Mac | no |
| control.music.albumArtworkPage | Choose an album picture | Music > Album | explained only | Mac | no |
| control.music.albumArtworkPrevious | Previous album picture | Music > Album | explained only | Mac | no |
| control.music.albumCompareClose | Close the comparison | Music > Album | explained only | Mac | no |
| control.music.albumCompareEditions | Compare editions | Music > Album | explained only | Mac | no |
| control.music.albumCompareOpen | Open the compared edition | Music > Album | explained only | Mac | no |
| control.music.albumContributorClose | Close the contributor list | Music > Album | explained only | Mac | no |
| control.music.albumContributorOpen | Open the contributor page | Music > Album | explained only | Mac | no |
| control.music.albumContributorSongs | Songs of a contributor | Music > Album | explained only | Mac | no |
| control.music.albumCoverClose | Close the cover window | Music > Album | explained only | Mac | no |
| control.music.albumCoverOpen | Open the album cover | Music > Album | explained only | Mac | no |
| control.music.albumCoverZoomIn | Zoom in on the album cover | Music > Album | explained only | Mac | no |
| control.music.albumCoverZoomOut | Zoom out of the album cover | Music > Album | explained only | Mac | no |
| control.music.albumDiscMenu | Disc menu | Music > Album | explained only | Mac | no |
| control.music.albumDiscToggle | Collapse or expand a disc | Music > Album | explained only | Mac | no |
| control.music.albumDownload | Download the album | Music > Album | explained only | Mac | no |
| control.music.albumExport | Export the tracklist | Music > Album | explained only | Mac | no |
| control.music.albumFilmCard | Open the film of this soundtrack | Music > Album | explained only | Mac | no |
| control.music.albumGoToArtist | Go to the album artist | Music > Album | explained only | Mac | no |
| control.music.albumGoToFilm | Go to the film | Music > Album | explained only | Mac | no |
| control.music.albumHideEdition | Hide an edition | Music > Album | explained only | Mac | no |
| control.music.albumInformation | Album information | Music > Album | explained only | Mac | no |
| control.music.albumNotesField | Notes about the album | Music > Album | explained only | Mac | no |
| control.music.albumPersonal | Your rating and notes | Music > Album | explained only | Mac | no |
| control.music.albumPersonalClose | Close your rating and notes | Music > Album | explained only | Mac | no |
| control.music.albumPersonalSave | Save your rating and notes | Music > Album | explained only | Mac | no |
| control.music.albumPlayMode | Choose how to play the album | Music > Album | explained only | Mac | no |
| control.music.albumPlayModesMenu | Album play options | Music > Album | explained only | Mac | no |
| control.music.albumPlayUnplayed | Play the songs you have not played | Music > Album | explained only | Mac | no |
| control.music.albumRadioButton | Start a radio from the album | Music > Album | explained only | Mac | no |
| control.music.albumRatingStar | Rate the album | Music > Album | explained only | Mac | no |
| control.music.albumRefresh | Refresh album details | Music > Album | explained only | Mac | no |
| control.music.albumRestoreEdition | Restore a hidden edition | Music > Album | explained only | Mac | no |
| control.music.albumSelectAll | Select or clear all songs | Music > Album | explained only | Mac | no |
| control.music.albumSelectLike | Like the chosen songs | Music > Album | explained only | Mac | no |
| control.music.albumSelectPlayNext | Play the chosen songs next | Music > Album | explained only | Mac | no |
| control.music.albumSelectPlaylist | Add the chosen songs to a playlist | Music > Album | explained only | Mac | no |
| control.music.albumSelectQueue | Add the chosen songs to the queue | Music > Album | explained only | Mac | no |
| control.music.albumSelectToggle | Select songs of the album | Music > Album | explained only | Mac | no |
| control.music.albumSetPreferred | Set the preferred edition | Music > Album | explained only | Mac | no |
| control.music.albumShowEditions | Show other editions | Music > Album | explained only | Mac | no |
| control.music.albumTagsField | Collection tags | Music > Album | explained only | Mac | no |
| control.music.albumTrackFilter | Filter the songs of an album | Music > Album | explained only | Mac | no |
| control.music.albumTrackSearch | Search inside an album | Music > Album | explained only | Mac | no |
| control.music.albumTrackSort | Sort the songs of an album | Music > Album | explained only | Mac | no |
| control.music.albumTrackSortMenu | Sort and filter menu of an album | Music > Album | explained only | Mac | no |
| control.music.albumTracksRetry | Try loading the missing songs again | Music > Album | explained only | Mac | no |
| control.music.albumVersionMenu | Edition options | Music > Album | explained only | Mac | no |
| control.music.albumVersionOpen | Open another version of the album | Music > Album | explained only | Mac | no |
| control.music.albumViewArtwork | View album artwork | Music > Album | explained only | Mac | no |
| control.music.albumViewCredits | View album credits | Music > Album | explained only | Mac | no |
| control.music.artistAddToQueue | Add the artist's top songs to the queue | Music > Artist > More | explained only | Mac | no |
| control.music.artistAlbumDecade | Filter albums by decade | Music > Artist > Albums | explained only | Mac | no |
| control.music.artistAlbumLayout | Albums as grid or list | Music > Artist > Albums | explained only | Mac | no |
| control.music.artistAlbumRow | Open an album from the list | Music > Artist > Albums | explained only | Mac | no |
| control.music.artistAlbumType | Filter albums by type | Music > Artist > Albums | explained only | Mac | no |
| control.music.artistAlbumsMore | Show more albums | Music > Artist > Albums | explained only | Mac | no |
| control.music.artistAwardsMore | Show more awards | Music > Artist > About | explained only | Mac | no |
| control.music.artistCombine | Combine with a collaborator | Music > Artist > Collaborators | explained only | Mac | no |
| control.music.artistCopyLink | Copy the artist's link | Music > Artist > More | explained only | Mac | no |
| control.music.artistCreatePlaylist | Create a playlist from the artist | Music > Artist > More | explained only | Mac | no |
| control.music.artistExclude | Exclude or include an artist in recommendations | Music > Artist > More | explained only | Mac | no |
| control.music.artistExplore | Explore songs by language or decade | Music > Artist | explained only | Mac | no |
| control.music.artistFavorite | Favorite an artist | Music > Artist | explained only | Mac | no |
| control.music.artistFilmCredit | Filter films by credit | Music > Artist > Films | explained only | Mac | no |
| control.music.artistFilmDecade | Filter films by decade | Music > Artist > Films | explained only | Mac | no |
| control.music.artistFilmDirector | Filter films by director | Music > Artist > Films | explained only | Mac | no |
| control.music.artistFilmGenre | Filter films by genre | Music > Artist > Films | explained only | Mac | no |
| control.music.artistFilmIndustry | Filter films by industry | Music > Artist > Films | explained only | Mac | no |
| control.music.artistFilmSoundtrack | Films with a soundtrack | Music > Artist > Films | explained only | Mac | no |
| control.music.artistFilmsMore | Show more films | Music > Artist > Films | explained only | Mac | no |
| control.music.artistListeningMore | Show more unplayed songs | Music > Artist > Your listening | explained only | Mac | no |
| control.music.artistMilestone | Open a career milestone | Music > Artist > Timeline | explained only | Mac | no |
| control.music.artistMore | More actions for an artist | Music > Artist > More | explained only | Mac | no |
| control.music.artistPill | Switch an artist page section | Music > Artist | explained only | Mac | no |
| control.music.artistPlayNext | Play the artist's top songs next | Music > Artist > More | explained only | Mac | no |
| control.music.artistRadioMode | Start one radio mode | Music > Artist > Radio | explained only | Mac | no |
| control.music.artistRadioModes | Radio modes | Music > Artist > Radio | explained only | Mac | no |
| control.music.artistShare | Share the artist | Music > Artist > More | explained only | Mac | no |
| control.music.artistSongDecade | Filter an artist's songs by decade | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongFilm | Filter an artist's songs by film | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongLanguage | Filter an artist's songs by language | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongLiked | Only songs you liked | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongSearch | Search an artist's songs | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongSort | Sort an artist's songs | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongType | Filter an artist's songs by type | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongYearFrom | Songs from a year | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongYearTo | Songs up to a year | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongsMore | Show more songs | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongsPlay | Play these songs | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistSongsShuffle | Shuffle these songs | Music > Artist > Songs | explained only | Mac | no |
| control.music.artistTimelineYear | Open a year of the timeline | Music > Artist > Timeline | explained only | Mac | no |
| control.music.artistTopPlayed | Play one of your most played songs | Music > Artist > Your listening | explained only | Mac | no |
| control.music.artistWebsite | Open the artist's official website | Music > Artist > About | explained only | Mac | no |
| control.music.artistYearClear | Clear the year filter | Music > Artist | explained only | Mac | no |
| control.music.artworkCacheClear | Picture cache | Music > Menus | explained only | Mac | no |
| control.music.artworkCacheConfirm | Clear cache | Music > Menus | explained only | Mac | no |
| control.music.artworkChoose | Choose picture | Music > Menus | explained only | Mac | no |
| control.music.artworkCoverSettings | Cover settings | Music > Menus | explained only | Mac | no |
| control.music.artworkMenu | Manage artwork | Music > Menus | explained only | Mac | no |
| control.music.artworkOnline | Find pictures online | Music > Settings > Plugins & Sources > Metadata sources | explained only | Mac | no |
| control.music.artworkReset | Use automatic artwork | Music > Menus | explained only | Mac | no |
| control.music.audioBack | Back to the audio settings | Music > Now Playing | explained only | Mac | no |
| control.music.audioCrossfade | Crossfade length | Music > Now Playing | explained only | Mac | no |
| control.music.audioEffectsOpen | Open tempo, pitch and reverb | Music > Now Playing | explained only | Mac | no |
| control.music.audioEqualizerOpen | Open the equalizer | Music > Now Playing | explained only | Mac | no |
| control.music.audioNormalize | Normalise volume | Music > Now Playing | explained only | Mac | no |
| control.music.audioQualityChip | Audio quality chip | Music > Player bar | destination music | Mac | yes |
| control.music.audioSignalOpen | Open signal information | Music > Now Playing | explained only | Mac | no |
| control.music.automationAPIOn | A p i on | Music > Menus | explained only | Mac | no |
| control.music.automationAddAlarm | Add alarm | Music > Menus | explained only | Mac | no |
| control.music.automationAddKey | Add key | Music > Menus | explained only | Mac | no |
| control.music.automationAddPlay | Add play | Music > Menus | explained only | Mac | no |
| control.music.automationAddRule | Add rule | Music > Menus | explained only | Mac | no |
| control.music.automationAddStop | Add stop | Music > Menus | explained only | Mac | no |
| control.music.automationAddTrigger | Add trigger | Music > Menus | explained only | Mac | no |
| control.music.automationArgument | Argument | Music > Menus | explained only | Mac | no |
| control.music.automationClose | Close | Music > Menus | explained only | Mac | no |
| control.music.automationCommand | Command | Music > Menus | explained only | Mac | no |
| control.music.automationCopyToken | Copy token | Music > Menus | explained only | Mac | no |
| control.music.automationDay | Day | Music > Menus | explained only | Mac | no |
| control.music.automationDelete | Delete | Music > Menus | explained only | Mac | no |
| control.music.automationEnabled | Enabled | Music > Menus | explained only | Mac | no |
| control.music.automationEvent | Event | Music > Menus | explained only | Mac | no |
| control.music.automationFade | Fade | Music > Menus | explained only | Mac | no |
| control.music.automationGlobal | Global | Music > Menus | explained only | Mac | no |
| control.music.automationKeyDelete | Key delete | Music > Menus | explained only | Mac | no |
| control.music.automationLaunchOn | Launch on | Music > Menus | explained only | Mac | no |
| control.music.automationPermission | Permission | Music > Menus | explained only | Mac | no |
| control.music.automationRecordKey | Record key | Music > Menus | explained only | Mac | no |
| control.music.automationResetToken | Reset token | Music > Menus | explained only | Mac | no |
| control.music.automationRuleDelete | Rule delete | Music > Menus | explained only | Mac | no |
| control.music.automationRuleEnabled | Rule enabled | Music > Menus | explained only | Mac | no |
| control.music.automationRuleMatch | Rule match | Music > Menus | explained only | Mac | no |
| control.music.automationShowToken | Show token | Music > Menus | explained only | Mac | no |
| control.music.automationTab | Tab | Music > Menus | explained only | Mac | no |
| control.music.automationTime | Time | Music > Menus | explained only | Mac | no |
| control.music.automationTriggerDelete | Trigger delete | Music > Menus | explained only | Mac | no |
| control.music.automationTriggerEnabled | Trigger enabled | Music > Menus | explained only | Mac | no |
| control.music.autoplayMenuToggle | Autoplay in the shuffle menu | Music > Player and queue | explained only | Mac | yes |
| control.music.backPill | Back pill and history | Music > Page top | destination music | Mac | yes |
| control.music.backToTop | Back to top | Music > Pages | explained only | Mac | no |
| control.music.bannerDismiss | Close the results banner | Music > Pages | explained only | Mac | no |
| control.music.bannerRetry | Try the missing results again | Music > Pages | explained only | Mac | no |
| control.music.blockedSongsAllowAgain | Allow again | Music > Blocked songs | explained only | Mac | no |
| control.music.blockedSongsCancel | Cancel | Music > Blocked songs | explained only | Mac | no |
| control.music.blockedSongsClearAll | Clear All | Music > Blocked songs | explained only | Mac | no |
| control.music.blockedSongsClearTheWholeNeverPlayList | Clear the whole never-play list | Music > Blocked songs | explained only | Mac | no |
| control.music.cardPlay | Play from a card | Music > Cards | explained only | Mac | no |
| control.music.categoryPlay | Play a category | Music > Explore | explained only | Mac | no |
| control.music.categoryShowSongs | Show every song of a category | Music > Explore | explained only | Mac | no |
| control.music.categoryShuffle | Shuffle a category | Music > Explore | explained only | Mac | no |
| control.music.categoryTile | Music category | Music > Search | explained only | Mac | no |
| control.music.chartChooseVersion | Play this version | Music > Charts > Rows | explained only | Mac | no |
| control.music.chartChooseVersionMenu | Choose version (row menu) | Music > Charts > Rows | explained only | Mac | no |
| control.music.chartPlay | Play a chart | Music > Explore | explained only | Mac | no |
| control.music.chartShowUnavailable | Show or hide unavailable chart songs | Music > Explore | explained only | Mac | no |
| control.music.chartShuffle | Shuffle a chart | Music > Explore | explained only | Mac | no |
| control.music.chartVersionChip | Choose a version of a chart song | Music > Charts > Rows | explained only | Mac | no |
| control.music.chooseAnotherSourceCancel | Cancel | Music > Choose another source | explained only | Mac | no |
| control.music.chooseAnotherSourceResetToAutomaticMatching | Reset to automatic matching | Music > Choose another source | explained only | Mac | no |
| control.music.chooseAnotherSourceSArtist | Choose this copy of the song | Music > Choose another source | explained only | Mac | yes |
| control.music.chooseAnotherSourceUseTheSelectedRecordingForThis | Use the selected recording for this song | Music > Choose another source | explained only | Mac | no |
| control.music.classicalChoose | Choose classical raga | Music > Menus | explained only | Mac | no |
| control.music.classicalImport | Choose dataset folder | Music > Menus | explained only | Mac | no |
| control.music.classicalImportStop | Stop reading the dataset | Music > Menus | explained only | Mac | no |
| control.music.classicalKind | Ragas or Talas | Music > Menus | explained only | Mac | no |
| control.music.classicalPlay | Play classical recording | Music > Menus | explained only | Mac | no |
| control.music.classicalSearch | Search classical ragas | Music > Menus | explained only | Mac | no |
| control.music.classicalTradition | Carnatic or Hindustani | Music > Menus | explained only | Mac | no |
| control.music.collectionMenuDownload | Download an album or playlist | Music > Menus | explained only | Mac | no |
| control.music.collectionMenuEdit | Edit playlist | Music > Menus | explained only | Mac | no |
| control.music.collectionMenuExport | Export playlist | Music > Menus | explained only | Mac | no |
| control.music.collectionMenuExportFormat | Export format | Music > Menus | explained only | Mac | no |
| control.music.collectionMenuRemoveDuplicates | Remove duplicates | Music > Menus | explained only | Mac | no |
| control.music.collectionMenuSelect | Select multiple | Music > Menus | explained only | Mac | no |
| control.music.collectionMenuSort | Sort tracks | Music > Menus | explained only | Mac | no |
| control.music.collectionMenuSortKey | Sort by | Music > Menus | explained only | Mac | no |
| control.music.collectionMenuSortReverse | Reverse order | Music > Menus | explained only | Mac | no |
| control.music.combineClear | Remove person | Music > Menus | explained only | Mac | no |
| control.music.combineClose | Close | Music > Menus | explained only | Mac | no |
| control.music.combineComposer | Composed by | Music > Menus | explained only | Mac | no |
| control.music.combineDecade | Decade | Music > Menus | explained only | Mac | no |
| control.music.combineKind | Kind of music | Music > Menus | explained only | Mac | no |
| control.music.combineLanguage | Language | Music > Menus | explained only | Mac | no |
| control.music.combineLyricist | Written by | Music > Menus | explained only | Mac | no |
| control.music.combineOpenFilm | Open a film from Combine | Music > Combine | explained only | Mac | no |
| control.music.combineOpenPossible | Open possible match | Music > Menus | explained only | Mac | no |
| control.music.combineOpenSong | Open song | Music > Menus | explained only | Mac | no |
| control.music.combinePickPerson | Choose person | Music > Menus | explained only | Mac | no |
| control.music.combinePlayAll | Play all | Music > Menus | explained only | Mac | no |
| control.music.combineRaga | Raga | Music > Menus | explained only | Mac | no |
| control.music.combineRun | Find songs | Music > Menus | explained only | Mac | no |
| control.music.combineSinger | Sung by | Music > Menus | explained only | Mac | no |
| control.music.comments | Song comments | Music > Player | explained only | Mac | no |
| control.music.commentsCancel | Cancel | Music > Comments | explained only | Mac | no |
| control.music.commentsDelete | Delete | Music > Comments | explained only | Mac | no |
| control.music.commentsEdit | Edit | Music > Comments | explained only | Mac | no |
| control.music.commentsMusiccommentsviewactionsButton | Comment actions | Music > Comments | explained only | Mac | yes |
| control.music.commentsMusiccommentsviewcomposerKeyboardShortcut | Send a comment | Music > Comments | explained only | Mac | yes |
| control.music.commentsMusiccommentsviewcomposerOnTapGesture | Music comments view composer click | Music > Comments | explained only | Mac | no |
| control.music.commentsMusiccommentsviewmessageblockButton | A comment | Music > Comments | explained only | Mac | yes |
| control.music.commentsMusiccommentsviewsortrowButton | Sort comments | Music > Comments | explained only | Mac | yes |
| control.music.commentsMusiccommentsviewthreadviewButton | Open replies | Music > Comments | explained only | Mac | yes |
| control.music.commentsReply | Reply | Music > Comments | explained only | Mac | no |
| control.music.commentsShowLess | Show less | Music > Comments | explained only | Mac | no |
| control.music.commentsShowMoreReplies | Show more replies | Music > Comments | explained only | Mac | no |
| control.music.commentsTryAgain | Try Again | Music > Comments | explained only | Mac | no |
| control.music.concertOpen | Open the full setlist | Music > Menus | explained only | Mac | no |
| control.music.concertPlay | Play the songs I have | Music > Menus | explained only | Mac | no |
| control.music.concertRow | Concert | Music > Menus | explained only | Mac | no |
| control.music.concertsMore | Show more concerts | Music > Menus | explained only | Mac | no |
| control.music.contextClose | Close the details panel | Music > Details panel | explained only | Mac | no |
| control.music.contextScrim | Close the details panel by clicking outside | Music > Details panel | explained only | Mac | no |
| control.music.contextTab | Details panel tab | Music > Details panel | explained only | Mac | yes |
| control.music.contextToggle | Show or hide the details panel | Music > Page top right | explained only | Mac | yes |
| control.music.convertBitrate | Quality | Music > Menus | explained only | Mac | no |
| control.music.convertCancel | Cancel this conversion | Music > Menus | explained only | Mac | no |
| control.music.convertCancelAll | Cancel all conversions | Music > Menus | explained only | Mac | no |
| control.music.convertChannels | Channels | Music > Menus | explained only | Mac | no |
| control.music.convertChoose | Choose files | Music > Menus | explained only | Mac | no |
| control.music.convertClearFiles | Clear files | Music > Menus | explained only | Mac | no |
| control.music.convertClearList | Clear the list | Music > Menus | explained only | Mac | no |
| control.music.convertClose | Close audio tools | Music > Menus | explained only | Mac | no |
| control.music.convertDepth | Bit depth | Music > Menus | explained only | Mac | no |
| control.music.convertDiscFormat | Format of the imported tracks | Music > Menus | explained only | Mac | no |
| control.music.convertDiscImport | Import the disc | Music > Menus | explained only | Mac | no |
| control.music.convertDiscLook | Look for a disc | Music > Menus | explained only | Mac | no |
| control.music.convertEmbedCover | Store a picture in a file | Music > Menus | explained only | Mac | no |
| control.music.convertExtractCover | Save cover from a file | Music > Menus | explained only | Mac | no |
| control.music.convertFolder | Choose the output folder | Music > Menus | explained only | Mac | no |
| control.music.convertFormat | Output format | Music > Menus | explained only | Mac | no |
| control.music.convertJoin | Join into one file | Music > Menus | explained only | Mac | no |
| control.music.convertJoinName | Name of the joined file | Music > Menus | explained only | Mac | no |
| control.music.convertPreset | Conversion preset | Music > Menus | explained only | Mac | no |
| control.music.convertPresetName | Preset name | Music > Menus | explained only | Mac | no |
| control.music.convertRate | Sample rate | Music > Menus | explained only | Mac | no |
| control.music.convertReveal | Show the new file in Finder | Music > Menus | explained only | Mac | no |
| control.music.convertSavePreset | Save preset | Music > Menus | explained only | Mac | no |
| control.music.convertSplit | Split into tracks | Music > Menus | explained only | Mac | no |
| control.music.convertSplitChoose | Choose the CD image | Music > Menus | explained only | Mac | no |
| control.music.convertSplitFormat | Format of the split tracks | Music > Menus | explained only | Mac | no |
| control.music.convertStart | Convert | Music > Menus | explained only | Mac | no |
| control.music.convertTab | Audio tools section | Music > Menus | explained only | Mac | no |
| control.music.convertTrimEnd | Keep until | Music > Menus | explained only | Mac | no |
| control.music.convertTrimStart | Keep from | Music > Menus | explained only | Mac | no |
| control.music.creditsAlbum | Open the song's album | Music > Details panel > Credits | explained only | Mac | no |
| control.music.creditsFilm | Open the song's film | Music > Details panel > Credits | explained only | Mac | no |
| control.music.creditsPerson | Open a credited person | Music > Details panel > Credits | explained only | Mac | no |
| control.music.devicesAllowOtherDevicesToControlThis | Allow other devices to control this one | Music > Devices | explained only | Mac | yes |
| control.music.devicesCancel | Cancel | Music > Devices | explained only | Mac | yes |
| control.music.devicesConnectTo | Connect to | Music > Devices | explained only | Mac | yes |
| control.music.devicesCopyCode | Copy code | Music > Devices | explained only | Mac | yes |
| control.music.devicesDisconnect | Disconnect | Music > Devices | explained only | Mac | yes |
| control.music.devicesLookForMyDevices | Look for my devices | Music > Devices | explained only | Mac | yes |
| control.music.devicesMusicdevicespagepairedrowButton | A paired device | Music > Devices | explained only | Mac | yes |
| control.music.devicesMusicdevicespagetransportButton | Transport of the controlled device | Music > Devices | explained only | Mac | yes |
| control.music.devicesPair | Pair | Music > Devices | explained only | Mac | yes |
| control.music.devicesPairWith | Pair with | Music > Devices | explained only | Mac | yes |
| control.music.devicesRemove | Remove | Music > Devices | explained only | Mac | yes |
| control.music.devicesSendThisDeviceSQueueTo | Send this device's queue to | Music > Devices | explained only | Mac | yes |
| control.music.devicesShowAPairingCodeForAnother | Show a pairing code for another device | Music > Devices | explained only | Mac | yes |
| control.music.devicesStopLooking | Stop looking | Music > Devices | explained only | Mac | yes |
| control.music.devicesTryAgain | Try again | Music > Devices | explained only | Mac | yes |
| control.music.downloadsCancelDownloadOf | Cancel download of | Music > Downloads | explained only | Mac | no |
| control.music.downloadsGroupOpen | Open a downloads group | Music > Downloads | explained only | Mac | no |
| control.music.downloadsPlayOffline | Play offline | Music > Downloads | explained only | Mac | no |
| control.music.downloadsRemoveDownloadOf | Remove download of | Music > Downloads | explained only | Mac | no |
| control.music.downloadsTryAgain | Try again | Music > Downloads | explained only | Mac | no |
| control.music.effectsCancel | Cancel | Music > Effects | explained only | Mac | yes |
| control.music.effectsDeletePreset | Delete preset | Music > Effects | explained only | Mac | yes |
| control.music.effectsDone | Done | Music > Effects | explained only | Mac | yes |
| control.music.effectsEqualizer | Equalizer | Music > Effects | explained only | Mac | yes |
| control.music.effectsMusiceffectspopoverreverbblockButton | Reverb amount | Music > Player bar > Effects | explained only | Mac | yes |
| control.music.effectsPopover | Tempo, pitch and reverb | Music > Player bar > Effects | destination music | Mac | yes |
| control.music.effectsPreset | Preset | Music > Effects | explained only | Mac | yes |
| control.music.effectsResetAllEffects | Reset all effects | Music > Effects | explained only | Mac | yes |
| control.music.effectsResetPitch | Reset pitch | Music > Effects | explained only | Mac | yes |
| control.music.effectsResetTempo | Reset tempo | Music > Effects | explained only | Mac | yes |
| control.music.effectsReverb | Reverb | Music > Effects | explained only | Mac | yes |
| control.music.effectsSavePreset | Save preset | Music > Effects | explained only | Mac | yes |
| control.music.effectsSaveTheCurrentSoundAsA | Save the current sound as a preset | Music > Effects | explained only | Mac | yes |
| control.music.effectsTempoPitchAndReverb | Tempo, pitch and reverb | Music > Effects | explained only | Mac | yes |
| control.music.eqAddBand | Add band | Music > Menus | explained only | Mac | no |
| control.music.eqAutoPreamp | Automatic preamp | Music > Equalizer | explained only | Mac | no |
| control.music.eqBalance | Balance | Music > Menus | explained only | Mac | no |
| control.music.eqBalanceCentre | Centre balance | Music > Menus | explained only | Mac | no |
| control.music.eqBandOn | Band on or off | Music > Menus | explained only | Mac | no |
| control.music.eqBandShape | Band shape | Music > Menus | explained only | Mac | no |
| control.music.eqImport | Import an equalizer preset file | Music > Equalizer | explained only | Mac | no |
| control.music.eqMono | Mono | Music > Menus | explained only | Mac | no |
| control.music.eqPad | Drag the bass and treble pad | Music > Equalizer | explained only | Mac | no |
| control.music.eqPresetApply | Use equalizer preset | Music > Menus | explained only | Mac | no |
| control.music.eqPresetCancel | Cancel saving preset | Music > Menus | explained only | Mac | no |
| control.music.eqPresetDelete | Delete this preset | Music > Menus | explained only | Mac | no |
| control.music.eqPresetDeleteMenu | Delete a preset | Music > Menus | explained only | Mac | no |
| control.music.eqPresetSaveConfirm | Save preset | Music > Menus | explained only | Mac | no |
| control.music.eqRememberPerOutput | Remember for each output | Music > Menus | explained only | Mac | no |
| control.music.eqRemoveBand | Remove band | Music > Menus | explained only | Mac | no |
| control.music.eqSavePreset | Save equalizer preset | Music > Menus | explained only | Mac | no |
| control.music.eqYourPresets | Your equalizer presets | Music > Menus | explained only | Mac | no |
| control.music.equalizerAutomaticPreamp | Automatic preamp | Music > Equalizer | explained only | Mac | no |
| control.music.equalizerBackToEffects | Back to effects | Music > Equalizer | explained only | Mac | no |
| control.music.equalizerCentreTheTonePad | Centre the tone pad | Music > Equalizer | explained only | Mac | no |
| control.music.equalizerEqualizer | Equalizer | Music > Equalizer | explained only | Mac | no |
| control.music.equalizerEqualizerPreset | Equalizer preset | Music > Equalizer | explained only | Mac | no |
| control.music.equalizerImportAnEqualizerPresetFile | Import an equalizer preset file | Music > Equalizer | explained only | Mac | no |
| control.music.equalizerResetTheEqualizer | Reset the equalizer | Music > Equalizer | explained only | Mac | no |
| control.music.equalizerStereoWidening | Stereo widening | Music > Equalizer | explained only | Mac | no |
| control.music.errorRetry | Try a failed page again | Music > Pages | explained only | Mac | no |
| control.music.expandedPlayerChooseAnotherAudioSource | Choose another audio source | Music > Expanded player | explained only | Mac | no |
| control.music.expandedPlayerClose | Close | Music > Expanded player | explained only | Mac | no |
| control.music.expandedPlayerCloseFullWindowNowPlaying | Close full-window Now Playing | Music > Expanded player | explained only | Mac | no |
| control.music.expandedPlayerMusicexpandedplayertopbarButton | Full-window player top controls | Music > Now Playing | explained only | Mac | yes |
| control.music.expandedPlayerMusicexpandedtransportbodyButton | Full-window player transport | Music > Now Playing | explained only | Mac | yes |
| control.music.expandedPlayerNext | Next | Music > Expanded player | explained only | Mac | no |
| control.music.expandedPlayerPrevious | Previous | Music > Expanded player | explained only | Mac | no |
| control.music.expandedPlayerRetry | Retry in the full-window player | Music > Expanded player | explained only | Mac | no |
| control.music.exploreChartShowAll | Show all chart songs | Music > Menus | explained only | Mac | no |
| control.music.exploreFeatureCards | Explore feature cards | Music > Explore | destination music | Mac | yes |
| control.music.exploreGenre | Open a genre | Music > Explore | explained only | Mac | no |
| control.music.exploreHeroOpen | Open the featured item | Music > Explore | explained only | Mac | no |
| control.music.exploreHeroPlay | Play the featured item | Music > Explore | explained only | Mac | yes |
| control.music.exploreLanguageTile | Language tile on Explore | Music > Explore > Languages | destination music | Mac | yes |
| control.music.exploreRagas | Ragas | Music > Menus | explained only | Mac | no |
| control.music.exploreSeeAllBack | Back to Explore | Music > Menus | explained only | Mac | no |
| control.music.exploreSeeAllPage | Explore shelf, full page | Music > Menus | explained only | Mac | no |
| control.music.exploreSeeAllPlay | Play the whole Explore list | Music > Menus | explained only | Mac | no |
| control.music.exploreShuffleChart | Shuffle the chart | Music > Explore > Chart | destination music | Mac | yes |
| control.music.facetSearch | Search for the language or era | Music > Explore > Languages and eras | explained only | Mac | no |
| control.music.filmActor | Open an actor | Music > Film info | explained only | Mac | no |
| control.music.filmAddToPlaylist | Add the film's songs to a playlist | Music > Film > Add to playlist | explained only | Mac | no |
| control.music.filmAddToQueue | Add the film's songs to the queue | Music > Film > More | explained only | Mac | no |
| control.music.filmCastSeeAll | See the whole cast | Music > Film > Overview | explained only | Mac | no |
| control.music.filmCrewSearch | Search the film's crew | Music > Film > Crew | explained only | Mac | no |
| control.music.filmCrewSearchClear | Clear the crew search | Music > Film > Crew | explained only | Mac | no |
| control.music.filmDubbedVersion | Open a dubbed soundtrack | Music > Film > Versions | explained only | Mac | no |
| control.music.filmFavourite | Like the film's songs | Music > Film > Favorite | explained only | Mac | no |
| control.music.filmGalleryClose | Close the picture | Music > Film > Gallery | explained only | Mac | no |
| control.music.filmGalleryImage | Open a film picture | Music > Film > Gallery | explained only | Mac | no |
| control.music.filmGalleryNext | Next picture | Music > Film > Gallery | explained only | Mac | no |
| control.music.filmGalleryPrevious | Previous picture | Music > Film > Gallery | explained only | Mac | no |
| control.music.filmInfoComposer | Open the music director | Music > Film info > Composer | explained only | Mac | no |
| control.music.filmInfoDirector | Open the director | Music > Film info > Director | explained only | Mac | no |
| control.music.filmInfoSinger | Open a singer | Music > Film info > Singers | explained only | Mac | no |
| control.music.filmPlayNext | Play the film's songs next | Music > Film > More | explained only | Mac | no |
| control.music.filmRadio | Film radio | Music > Film > Radio | explained only | Mac | no |
| control.music.filmShare | Share the film | Music > Film > Share | explained only | Mac | no |
| control.music.filmShareCopyLink | Copy the film's link | Music > Film > Share | explained only | Mac | no |
| control.music.filmSharePicker | Share the film with the system picker | Music > Film > Share | explained only | Mac | no |
| control.music.filmSynopsisMore | Show more of the synopsis | Music > Film > Synopsis | explained only | Mac | no |
| control.music.filmTrailer | Watch the trailer | Music > Film > About | explained only | Mac | no |
| control.music.filmVideoLink | Open a film video | Music > Film > Videos | explained only | Mac | no |
| control.music.filmViewFilm | View film | Music > Film info | explained only | Mac | no |
| control.music.filmViewInfo | View film info | Music > Film > More | explained only | Mac | no |
| control.music.filmWatchMovie | Watch Movie | Music > Film > Watch Movie | explained only | Mac | no |
| control.music.franchiseClose | Close | Music > Menus | explained only | Mac | no |
| control.music.franchiseFilm | Franchise film | Music > Menus | explained only | Mac | no |
| control.music.franchiseOpen | Franchise | Music > Menus | explained only | Mac | no |
| control.music.graphCastCard | Cast card | Music > Pages | explained only | Mac | no |
| control.music.graphCreditChip | Credited person | Music > Pages | explained only | Mac | no |
| control.music.graphFilmCard | Film card | Music > Pages | explained only | Mac | no |
| control.music.healthApplyRename | Rename files | Music > Menus | explained only | Mac | no |
| control.music.healthClose | Close library health | Music > Menus | explained only | Mac | no |
| control.music.healthDeep | Open every file | Music > Menus | explained only | Mac | no |
| control.music.healthExport | Export list | Music > Menus | explained only | Mac | no |
| control.music.healthPreview | Preview renaming | Music > Menus | explained only | Mac | no |
| control.music.healthReadOnly | Read-only collection | Music > Menus | explained only | Mac | no |
| control.music.healthReveal | Show in Finder | Music > Menus | explained only | Mac | no |
| control.music.healthRun | Check my library | Music > Menus | explained only | Mac | no |
| control.music.healthStop | Stop the check | Music > Menus | explained only | Mac | no |
| control.music.healthTab | Library health section | Music > Menus | explained only | Mac | no |
| control.music.healthTemplate | Rename template | Music > Menus | explained only | Mac | no |
| control.music.healthUndo | Undo this change | Music > Menus | explained only | Mac | no |
| control.music.healthUnlock | Unlock file | Music > Menus | explained only | Mac | no |
| control.music.homeChartCountry | Country picker | Music > Explore > Country | explained only | Mac | yes |
| control.music.homeContinueCard | Continue listening card | Music > Listen Now > Continue listening | explained only | Mac | yes |
| control.music.homeHeroOpen | Open the featured item | Music > Home | explained only | Mac | no |
| control.music.homeHeroPlay | Play the featured item | Music > Home | explained only | Mac | no |
| control.music.homeHeroTitle | Hero title | Music > Listen Now | explained only | Mac | no |
| control.music.homeMixPlay | Play a mix | Music > Listen Now | explained only | Mac | no |
| control.music.homeMixPlayNext | Play a mix next | Music > Listen Now | explained only | Mac | no |
| control.music.homeMixQueue | Add a mix to the queue | Music > Listen Now | explained only | Mac | no |
| control.music.homeMixShuffle | Shuffle a mix | Music > Listen Now | explained only | Mac | no |
| control.music.homeMoreExplore | Explore more: Explore | Music > Listen Now | explained only | Mac | no |
| control.music.homeMoreLibrary | Explore more: Your Library | Music > Listen Now | explained only | Mac | no |
| control.music.homeMoreRadio | Explore more: Radio | Music > Listen Now | explained only | Mac | no |
| control.music.homeMusichomepagebodyButton | A card on Listen Now | Music > Listen Now | explained only | Mac | yes |
| control.music.homeOpenLibrary | Open Library | Music > Listen Now | explained only | Mac | yes |
| control.music.homePlayRecent | Play recent | Music > Listen Now | explained only | Mac | yes |
| control.music.homeRefresh | Refresh Listen Now | Music > Listen Now | explained only | Mac | no |
| control.music.homeShuffleLiked | Shuffle liked | Music > Listen Now | explained only | Mac | yes |
| control.music.homeStartRadio | Start radio | Music > Listen Now | explained only | Mac | yes |
| control.music.homeTile | Listen Now tile | Music > Listen Now | explained only | Mac | no |
| control.music.homeTilePlay | Play a mix | Music > Listen Now > Made for you | explained only | Mac | no |
| control.music.homeTopTrackLike | Like a top track | Music > Listen Now > Your top tracks | explained only | Mac | no |
| control.music.homeTopTrackMenu | Top track menu | Music > Listen Now | explained only | Mac | no |
| control.music.homeTopTrackMore | More actions for a top track | Music > Listen Now > Your top tracks | explained only | Mac | no |
| control.music.homeTopTrackRow | Top track row | Music > Listen Now > Your top tracks | explained only | Mac | no |
| control.music.homeTopTrackText | Top track title | Music > Listen Now | explained only | Mac | no |
| control.music.homeWelcomeExplore | Explore charts | Music > Listen Now | explained only | Mac | no |
| control.music.homeWelcomeImport | Import or open a link | Music > Listen Now | explained only | Mac | no |
| control.music.homeWelcomeRadio | Start a radio | Music > Listen Now | explained only | Mac | no |
| control.music.identifyClose | Close | Music > Menus | explained only | Mac | no |
| control.music.identifyFill | Fill empty details | Music > Menus | explained only | Mac | no |
| control.music.identifyReplace | Use these details | Music > Menus | explained only | Mac | no |
| control.music.identifyWrite | Also write into the files | Music > Menus | explained only | Mac | no |
| control.music.import | Import playlists | Music > Your Library | explained only | Mac | no |
| control.music.importBack | Back | Music > Import | explained only | Mac | no |
| control.music.importCancel | Cancel | Music > Import | explained only | Mac | no |
| control.music.importChange | Change | Music > Import | explained only | Mac | no |
| control.music.importChangepickerbodyButton | Change what is imported | Music > Import | explained only | Mac | yes |
| control.music.importChooseFile | Choose file | Music > Import | explained only | Mac | no |
| control.music.importClose | Close | Music > Import | explained only | Mac | no |
| control.music.importContinue | Continue | Music > Import | explained only | Mac | no |
| control.music.importCopyMissingSongs | Copy missing songs | Music > Import | explained only | Mac | no |
| control.music.importCreate | Create | Music > Import | explained only | Mac | no |
| control.music.importFindSongs | Find songs | Music > Import | explained only | Mac | no |
| control.music.importImportAnother | Import another | Music > Import | explained only | Mac | no |
| control.music.importKeepBrowsing | Keep browsing | Music > Import | explained only | Mac | no |
| control.music.importKeepUpToDateWithSpotify | Keep up to date with the external service | Music > Import | explained only | Mac | no |
| control.music.importLeaveOut | Leave out | Music > Import | explained only | Mac | no |
| control.music.importLooksRight | Looks right | Music > Import | explained only | Mac | no |
| control.music.importOpen | Open | Music > Import | explained only | Mac | no |
| control.music.importSearch | Search | Music > Import | explained only | Mac | no |
| control.music.importSelectAll | Select all | Music > Import | explained only | Mac | no |
| control.music.importSelectNone | Select none | Music > Import | explained only | Mac | no |
| control.music.importShow | Show | Music > Import | explained only | Mac | no |
| control.music.importSongs | songs | Music > Import | explained only | Mac | no |
| control.music.importStartOver | Start over | Music > Import | explained only | Mac | no |
| control.music.importStop | Stop | Music > Import | explained only | Mac | no |
| control.music.importTryAgain | Try again | Music > Import | explained only | Mac | no |
| control.music.importTryAgainAt | Try again at | Music > Import | explained only | Mac | no |
| control.music.importUpdateAutomatically | Update automatically | Music > Import | explained only | Mac | no |
| control.music.jumpToPlaying | Jump to the playing song | Music > Song lists | explained only | Mac | no |
| control.music.karaoke | Karaoke | Music > Player > Lyrics | explained only | Mac | no |
| control.music.karaokeAgreeToTheLicenceAndDownload | Agree to the licence and download | Music > Karaoke | explained only | Mac | no |
| control.music.karaokeCancel | Cancel | Music > Karaoke | explained only | Mac | no |
| control.music.karaokeClear | Clear | Music > Karaoke | explained only | Mac | no |
| control.music.karaokeClearPreparedSongs | Clear prepared songs | Music > Karaoke | explained only | Mac | no |
| control.music.karaokeDelete | Delete | Music > Karaoke | explained only | Mac | no |
| control.music.karaokeDeleteModel | Delete model | Music > Karaoke | explained only | Mac | no |
| control.music.karaokeDismiss | Dismiss | Music > Karaoke | explained only | Mac | no |
| control.music.karaokeDownload | Download the karaoke model | Music > Settings > Playback > Karaoke | explained only | Mac | yes |
| control.music.karaokeGet | Get | Music > Karaoke | explained only | Mac | no |
| control.music.karaokeNotNow | Not now | Music > Karaoke | explained only | Mac | no |
| control.music.karaokeUse | Use | Music > Karaoke | explained only | Mac | no |
| control.music.libraryAddQueue | Add these songs to the queue | Music > Your Library | explained only | Mac | no |
| control.music.libraryChip | Remove an active filter | Music > Your Library | explained only | Mac | no |
| control.music.libraryClearFilters | Clear all filters | Music > Your Library | explained only | Mac | no |
| control.music.libraryCombine | Combine | Music > Menus | explained only | Mac | no |
| control.music.libraryDownload | Download these songs | Music > Your Library | explained only | Mac | no |
| control.music.libraryDownloads | Open Downloads | Music > Your Library | explained only | Mac | no |
| control.music.libraryEmptyAction | Fill an empty library | Music > Your Library | explained only | Mac | no |
| control.music.libraryEntityPlay | Play this item | Music > Your Library | explained only | Mac | no |
| control.music.libraryEntityQueue | Add this item to the queue | Music > Your Library | explained only | Mac | no |
| control.music.libraryEntityShuffle | Shuffle this item | Music > Your Library | explained only | Mac | no |
| control.music.libraryFacetChip | Genre or language chip | Music > Your Library | explained only | Mac | no |
| control.music.libraryFacetMenu | Genre or language menu | Music > Your Library | explained only | Mac | no |
| control.music.libraryFacetPicker | Genre or language filter | Music > Your Library | explained only | Mac | no |
| control.music.libraryFilter | Filter this tab | Music > Your Library | explained only | Mac | no |
| control.music.libraryFilterClear | Clear the filter text | Music > Your Library | explained only | Mac | no |
| control.music.libraryFolderCancel | Cancel a folder dialog | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.libraryFolderChoose | Choose the playlists in a folder | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.libraryFolderCreate | Create a playlist folder | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.libraryFolderDelete | Delete a playlist folder | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.libraryFolderDone | Done choosing playlists for a folder | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.libraryFolderNew | New playlist folder | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.libraryFolderRename | Rename a playlist folder | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.libraryFolderToggle | Put a playlist in the folder | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.libraryLocalCrumb | Go back up the folder path | Music > Your Library > Local files | explained only | Mac | no |
| control.music.libraryLocalCrumbRoot | All music folders | Music > Your Library > Local files | explained only | Mac | no |
| control.music.libraryLocalFolderRow | Open a music folder | Music > Your Library > Local files | explained only | Mac | no |
| control.music.libraryLocalFolders | Browse Local files by folder | Music > Your Library > Local files | explained only | Mac | no |
| control.music.libraryLocalPlayFolder | Play folder | Music > Your Library > Local files | explained only | Mac | no |
| control.music.libraryLocalShuffleFolder | Shuffle folder | Music > Your Library > Local files | explained only | Mac | no |
| control.music.libraryMore | More library actions | Music > Your Library | explained only | Mac | no |
| control.music.libraryNewPlaylist | New playlist | Music > Your Library | explained only | Mac | no |
| control.music.libraryPageBack | Your library | Music > Menus | explained only | Mac | no |
| control.music.libraryPlay | Play these songs | Music > Your Library | explained only | Mac | no |
| control.music.libraryPlayNext | Play these songs next | Music > Your Library | explained only | Mac | no |
| control.music.libraryQuickLink | Library quick links | Music > Your Library | explained only | Mac | no |
| control.music.libraryRecentlyAdded | Recently Added | Music > Sidebar > Library | destination music | Mac | yes |
| control.music.libraryRow | Library row | Music > Your Library | explained only | Mac | no |
| control.music.librarySelect | Select songs | Music > Your Library | explained only | Mac | no |
| control.music.libraryShowMore | Show more history | Music > Your Library | explained only | Mac | no |
| control.music.libraryShuffle | Shuffle these songs | Music > Your Library | explained only | Mac | no |
| control.music.librarySongActions | More actions for these songs | Music > Your Library | explained only | Mac | no |
| control.music.librarySort | Sort the library tab | Music > Your Library | explained only | Mac | no |
| control.music.librarySortReverse | Reverse the sort | Music > Your Library | explained only | Mac | no |
| control.music.librarySource | Filter the library by source | Music > Your Library | explained only | Mac | no |
| control.music.libraryTab | Library section | Music > Menus | explained only | Mac | no |
| control.music.libraryTabMenu | Choose a library section | Music > Your Library | explained only | Mac | no |
| control.music.libraryViewMode | Choose how the library is shown | Music > Your Library | explained only | Mac | no |
| control.music.listColumns | Choose song list columns | Music > Song lists | explained only | Mac | no |
| control.music.listFilter | Filter a song list | Music > Song lists | explained only | Mac | no |
| control.music.listScrollEnd | Scroll to the end of a song list | Music > Song lists | explained only | Mac | no |
| control.music.listSelect | Select songs | Music > Song lists | explained only | Mac | no |
| control.music.listSort | Sort a song list | Music > Song lists | explained only | Mac | no |
| control.music.listeningRoomAddToTheQueue | Add to the queue | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomCopyCode | Copy code | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomCopyInvite | Copy invite | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomDoNotAdd | Do not add | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomEndRoom | End room | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomJoin | Join | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomJoinTheRoomOn | Join the room on | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomLeaveTheRoom | Leave the room | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomLetIn | Let in | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomLookForRooms | Look for rooms | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomMusicroompagesuggestmenuButton | Suggest a song to the host | Music > Listen Together | explained only | Mac | yes |
| control.music.listeningRoomRefuse | Refuse | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomRemoveFromTheRoom | Remove from the room | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomShareInvite | Share invite | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomShowANewRoomCode | Show a new room code | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomStartARoomOnThisDevice | Start a room on this device | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomStopLooking | Stop looking | Music > Listening room | explained only | Mac | yes |
| control.music.listeningRoomSuggestASongToTheHost | Suggest a song to the host | Music > Listening room | explained only | Mac | yes |
| control.music.loadMoreRetry | Try loading more again | Music > Song lists | explained only | Mac | no |
| control.music.lyricsAlignment | Lyrics alignment | Music > Lyrics | explained only | Mac | no |
| control.music.lyricsAutomaticFirstMatchInYourOrder | Automatic: first match in your order | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsBackToThisSong | Back to this song | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsBadLyrics | Bad lyrics | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsBrowse | Scroll the lyrics yourself | Music > Lyrics | explained only | Mac | no |
| control.music.lyricsCancelPickingLines | Cancel picking lines | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsCopyTheLyricsAsText | Copy the lyrics as text | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsDone | Done | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsEditWordEdge | Drag the edge of a word in the lyrics editor | Music > Lyrics > Editor | explained only | Mac | no |
| control.music.lyricsEditorAddABreakBelow | Add a break below | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorAddALine | Add a line | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorAddALineBelow | Add a line below | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorAddAnInstrumentalBreak | Add an instrumental break | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorBackToEditing | Back to editing | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorCancel | Cancel | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorChooseWhereTheLyricsStartFrom | Choose where the lyrics start from | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorCloseTheEditor | Close the editor | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorDelete | Delete | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorDiscardDraft | Discard draft | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorEditorStep | Editor step | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorEveryone | Everyone | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorFlowwordsbodyButton | Lyrics editor: word | Music > Lyrics > Editor | explained only | Mac | yes |
| control.music.lyricsEditorGoToTheNextLineTo | Go to the next line to do | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorGoToTheTimingStep | Go to the timing step | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorImportAFile | Import a file | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorJoinWithNextLine | Join with next line | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorLineActions | Line actions | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorLoadTheNewVersion | Load the new version | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorLookingAtOtherSources | Looking at other sources | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorLoopTheLine | Loop the line | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorMusiclyricseditorviewcontrolsButton | Lyrics editor: playback controls | Music > Lyrics > Editor | explained only | Mac | yes |
| control.music.lyricsEditorMusiclyricseditorviewlinelistButton | Lyrics editor: lines | Music > Lyrics > Editor | explained only | Mac | yes |
| control.music.lyricsEditorMusiclyricseditorviewpreviewButton | Lyrics editor: preview | Music > Lyrics > Editor | explained only | Mac | yes |
| control.music.lyricsEditorMusiclyricseditorviewtextstepButton | Lyrics editor: text step | Music > Lyrics > Editor | explained only | Mac | yes |
| control.music.lyricsEditorMusiclyricstimelinestripbodyOnTapGesture | Music lyrics timeline strip body click | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorNoSinger | No singer | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorPasteText | Paste text | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorPreview | Preview | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorReloadTheStartingLyrics | Reload the starting lyrics | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorRestartThisLine | Restart this line | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorSendLyrics | Send lyrics | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorSendMineOnTop | Send mine on top | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorSinger | Singer | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorSinger1 | Singer 1 | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorSinger2 | Singer 2 | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorSingerOfThisLine | Singer of this line | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorSplitTheWordsAgain | Split the words again | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorSubmitTheseLyricsToTheCommunity | Submit these lyrics to the community lyrics service | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorTapAWordStartsNow | Tap: a word starts now | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorToggleTheSelectedWordAsA | Toggle the selected word as a background vocal | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorUseThisText | Use this text | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorVoiceBeingTimed | Voice being timed | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsEditorWatchThePreview | Watch the preview | Music > Lyrics editor | explained only | Mac | no |
| control.music.lyricsGoodLyrics | Good lyrics | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsJumpToCurrentLine | Jump to current line | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsLargerLyricsText | Larger lyrics text | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsLongPress | Hold a lyric line | Music > Lyrics | explained only | Mac | no |
| control.music.lyricsLyricsSourceChooseAnother | Choose another lyrics source | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsMusiclyricsrowbodyButton | A lyric line | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsMusiclyricssourcepickercontributionrowButton | A lyrics contribution | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsMusiclyricstoolbartoggleButton | A lyrics toolbar toggle | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsPickLinesToShare | Pick lines to share | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsPreviewFull | Open the full lyrics | Music > Details panel > Lyrics | explained only | Mac | no |
| control.music.lyricsPreviewLine | Play from a lyric line | Music > Details panel > Lyrics | explained only | Mac | no |
| control.music.lyricsReason | Reason | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsReportAProblemWithTheseLyrics | Report a problem with these lyrics | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsResetTheLyricsOffset | Reset the lyrics offset | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsSearchAgain | Search for lyrics again | Music > Details panel > Lyrics | explained only | Mac | no |
| control.music.lyricsSearchSourcesWithTheseWords | Search sources with these words | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsSent | Sent | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsSharePickedLines | Share picked lines | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsShowLyricsEarlier | Show lyrics earlier | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsShowLyricsLater | Show lyrics later | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsShowTheAppNameOnThe | Show the app name on the card | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsSmallerLyricsText | Smaller lyrics text | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsStripClear | More see-through lyrics background | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripClose | Close lyrics | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripLarger | Larger lyrics text | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripLine | Lyric line | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripPanel | Open lyrics in the side panel | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripPanelLink | Open unsynced lyrics in the side panel | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripRetry | Try loading lyrics again | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripRomanisation | Show romanisation in the lyrics strip | Music > Lyrics | explained only | Mac | no |
| control.music.lyricsStripSmaller | Smaller lyrics text | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripSolid | More solid lyrics background | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripStyle | Lyrics style | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripStyleChoice | Lyrics strip style | Music > Menus | explained only | Mac | no |
| control.music.lyricsStripTranslation | Show translation on the strip | Music > Menus | explained only | Mac | no |
| control.music.lyricsTranslateTheLyricsOnThisDevice | Translate the lyrics on this device | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsUseTheStoryLayout | Use the story layout | Music > Lyrics | explained only | Mac | yes |
| control.music.lyricsVia | via | Music > Lyrics | explained only | Mac | yes |
| control.music.mainWindowBack | Back | Music > Main window | explained only | Mac | no |
| control.music.mainWindowCloseComments | Close comments | Music > Main window | explained only | Mac | no |
| control.music.mainWindowClosePanel | Close panel | Music > Main window | explained only | Mac | no |
| control.music.mainWindowForward | Forward | Music > Main window | explained only | Mac | no |
| control.music.mainWindowMusicmainviewpaletteOnTapGesture | Music main view palette click | Music > Main window | explained only | Mac | no |
| control.music.mainWindowQuickSearch | Quick Search | Music > Main window | explained only | Mac | no |
| control.music.mainWindowSearch | Search | Music > Main window | explained only | Mac | no |
| control.music.marksBookmarkAdd | Bookmark here | Music > Menus | explained only | Mac | no |
| control.music.marksBookmarkJump | Go to bookmark | Music > Menus | explained only | Mac | no |
| control.music.marksBookmarkName | Bookmark name | Music > Menus | explained only | Mac | no |
| control.music.marksBookmarkNext | Next bookmark | Music > Menus | explained only | Mac | no |
| control.music.marksBookmarkPrev | Previous bookmark | Music > Menus | explained only | Mac | no |
| control.music.marksBookmarkRemove | Remove bookmark | Music > Menus | explained only | Mac | no |
| control.music.marksBoundsClear | Reset start, stop and skips | Music > Menus | explained only | Mac | no |
| control.music.marksChapter | Chapter | Music > Menus | explained only | Mac | no |
| control.music.marksClose | Close song navigation | Music > Menus | explained only | Mac | no |
| control.music.marksEnd | Stop here | Music > Menus | explained only | Mac | no |
| control.music.marksIntro | Intro to skip | Music > Menus | explained only | Mac | no |
| control.music.marksLoopA | Loop start (A) | Music > Menus | explained only | Mac | no |
| control.music.marksLoopB | Loop end (B) | Music > Menus | explained only | Mac | no |
| control.music.marksLoopClear | Clear loop | Music > Menus | explained only | Mac | no |
| control.music.marksLoopToggle | Repeat this part | Music > Menus | explained only | Mac | no |
| control.music.marksOutro | Outro to skip | Music > Menus | explained only | Mac | no |
| control.music.marksSkipSave | Save skips | Music > Menus | explained only | Mac | no |
| control.music.marksSkipSilence | Skip the silence at the ends | Music > Menus | explained only | Mac | no |
| control.music.marksStart | Start here | Music > Menus | explained only | Mac | no |
| control.music.marksWaveform | Waveform | Music > Menus | explained only | Mac | no |
| control.music.menuBarItem | Music menu bar item | Music > Settings > Playback | destination music | Mac | yes |
| control.music.menuChip | Filter menu | Music > Menus | explained only | Mac | no |
| control.music.menuChipChoice | Filter choice | Music > Menus | explained only | Mac | no |
| control.music.metaAlbum | Album field | Music > Menus | explained only | Mac | no |
| control.music.metaAlbumArtist | Album artist field | Music > Menus | explained only | Mac | no |
| control.music.metaArtist | Artist field | Music > Menus | explained only | Mac | no |
| control.music.metaCancel | Cancel | Music > Menus | explained only | Mac | no |
| control.music.metaDisc | Disc number field | Music > Menus | explained only | Mac | no |
| control.music.metaGenre | Genre field | Music > Menus | explained only | Mac | no |
| control.music.metaSave | Save | Music > Menus | explained only | Mac | no |
| control.music.metaTitle | Title field | Music > Menus | explained only | Mac | no |
| control.music.metaTrack | Track number field | Music > Menus | explained only | Mac | no |
| control.music.metaWriteFiles | Write changes into the files | Music > Menus | explained only | Mac | no |
| control.music.metaYear | Year field | Music > Menus | explained only | Mac | no |
| control.music.metadataSource | Switch a metadata source | Music > Settings > Plugins & Sources > Metadata sources | explained only | Mac | no |
| control.music.miniPlayerBackToTheApp | Back to the app | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerDislike | Dislike | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerDislikeRemoveThisSongFromThe | Dislike: remove this song from the queue | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerEmptyBack | Back to the app from an empty mini player | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerMakeTheMiniPlayerLarger | Make the mini player larger | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerMakeTheMiniPlayerSmaller | Make the mini player smaller | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerMusicminiplayerviewcompactlayoutButton | Mini player compact controls | Music > Mini player | explained only | Mac | yes |
| control.music.miniPlayerMusicminiplayerviewfulllayoutButton | Mini player controls | Music > Mini player | explained only | Mac | yes |
| control.music.miniPlayerMusicminiplayerviewtopclusterButton | Mini player top buttons | Music > Mini player | explained only | Mac | yes |
| control.music.miniPlayerNext | Next | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerOpenTheMiniPlayer | Open the mini player | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerPlay | Play | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerPrevious | Previous | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerQueueOrLyrics | Queue or lyrics | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerRepeat | Repeat | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerRetry | Retry in the mini player | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerShuffle | Shuffle | Music > Mini player | explained only | Mac | no |
| control.music.miniPlayerTheatreMode | Theatre mode | Music > Mini player | explained only | Mac | no |
| control.music.modesChoose | Choose a listening mode | Music > Menus | explained only | Mac | no |
| control.music.modesClose | Close listening modes | Music > Menus | explained only | Mac | no |
| control.music.modesOpen | Listening mode | Music > Menus | explained only | Mac | no |
| control.music.musicClear | Clear | Music > Music | explained only | Mac | no |
| control.music.musicClearPlaybackProblems | Clear playback problems | Music > Music | explained only | Mac | no |
| control.music.musicCopyPlaybackDiagnostics | Copy playback diagnostics | Music > Music | explained only | Mac | no |
| control.music.musicCouldNotLoadTryAgain | Try again after a page could not load | Music > Pages | explained only | Mac | yes |
| control.music.musicDone | Done | Music > Music | explained only | Mac | no |
| control.music.musicFindLyricsForThisTrack | Find lyrics for this track | Music > Music | explained only | Mac | no |
| control.music.musicMusicheaderbarbarButton | Music page buttons (Refresh, side panel) | Music > Page top right | explained only | Mac | yes |
| control.music.musicMusicpaletterowviewButton | A quick-search result | Music > Keyboard | explained only | Mac | yes |
| control.music.musicPlaylist | Playlist | Music > Music | explained only | Mac | no |
| control.music.musicSaveThePaxsenixKey | Save the PaxSenix key | Music > Settings > Lyrics > Lyrics sources | explained only | Mac | yes |
| control.music.musicTryAgain | Try Again | Music > Music | explained only | Mac | no |
| control.music.networkBack | Back | Music > Menus | explained only | Mac | no |
| control.music.networkClose | Close | Music > Menus | explained only | Mac | no |
| control.music.networkNode | Collaborator | Music > Menus | explained only | Mac | no |
| control.music.networkOpen | Open page | Music > Menus | explained only | Mac | no |
| control.music.networkOpenFromPerson | Collaborator network | Music > Menus | explained only | Mac | no |
| control.music.nowPlayingArtwork | Now Playing cover | Music > Now Playing | explained only | Mac | no |
| control.music.nowPlayingAudioSettings | Audio settings | Music > Now Playing | explained only | Mac | no |
| control.music.nowPlayingLinkChip | Now Playing link chip | Music > Now Playing | explained only | Mac | no |
| control.music.nowPlayingMode | Choose a Now Playing layout | Music > Now Playing | explained only | Mac | no |
| control.music.nowPlayingModeMenu | Now Playing layout | Music > Now Playing | explained only | Mac | no |
| control.music.nowPlayingTitleLink | Now Playing song title | Music > Now Playing | explained only | Mac | no |
| control.music.nowPlayingUpNext | Up next preview | Music > Now Playing | explained only | Mac | no |
| control.music.nowPlayingViewArtwork | View the cover large | Music > Now Playing | explained only | Mac | no |
| control.music.openALinkCancel | Cancel | Music > Open a link | explained only | Mac | no |
| control.music.openALinkOpen | Open | Music > Open a link | explained only | Mac | no |
| control.music.openLink | Open a music link | Music > Sidebar > More > Open a Link | explained only | Mac | yes |
| control.music.outputDevice | Choose the output device for Music | Music > Settings > Playback > Output device | explained only | Mac | no |
| control.music.pageMenu | Page menu | Music > Pages | explained only | Mac | no |
| control.music.palette | Quick search in Music | Music > Keyboard | explained only | Mac | yes |
| control.music.paletteField | Palette field | Music > Menus | explained only | Mac | no |
| control.music.paletteItem | Palette item | Music > Menus | explained only | Mac | no |
| control.music.panelResize | Resize the details panel | Music > Details panel | explained only | Mac | no |
| control.music.panelTabShortcut | Open a panel tab with the keyboard | Music > Details panel | explained only | Mac | no |
| control.music.perfClear | Clear responsiveness numbers | Music > Menus | explained only | Mac | no |
| control.music.perfCopy | Copy responsiveness report | Music > Menus | explained only | Mac | no |
| control.music.perfPages | Pages opened | Music > Menus | explained only | Mac | no |
| control.music.perfPlays | Play presses | Music > Menus | explained only | Mac | no |
| control.music.perfSlow | Slow moments | Music > Menus | explained only | Mac | no |
| control.music.personDidYouMean | Did you mean another person | Music > Person | explained only | Mac | no |
| control.music.personFollow | Follow a person | Music > Person | explained only | Mac | no |
| control.music.personLanguageFilter | Language filter | Music > Person page | explained only | Mac | no |
| control.music.personPlay | Play a person | Music > Person | explained only | Mac | no |
| control.music.personRadio | Start radio from a person | Music > Person | explained only | Mac | no |
| control.music.personRagaChip | Open raga | Music > Menus | explained only | Mac | no |
| control.music.personRole | Switch a person's role | Music > Person | explained only | Mac | no |
| control.music.personShowAll | Show all of a section | Music > Person | explained only | Mac | no |
| control.music.personShuffle | Shuffle a person | Music > Person | explained only | Mac | no |
| control.music.personSongOpen | Open a song from a person page | Music > Person | explained only | Mac | no |
| control.music.personSongPlay | Play one song of a person | Music > Person | explained only | Mac | no |
| control.music.playerAndQueueAutoplay | Autoplay | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueBackTo | Back to | Music > Player and queue | explained only | Mac | no |
| control.music.playerAndQueueCancelSleepTimer | Cancel Sleep Timer | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueChooseAnotherAudioSource | Choose Another Audio Source | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueClearQueue | Clear the queue | Music > Queue | explained only | Mac | yes |
| control.music.playerAndQueueComments | Comments | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueEditLyrics | Edit lyrics | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueGoToAlbum | Go to album | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueGoToArtist | Go to artist | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueLyrics | Lyrics (player bar) | Music > Player bar | explained only | Mac | yes |
| control.music.playerAndQueueMoreActionsFor | More actions for | Music > Player and queue | explained only | Mac | no |
| control.music.playerAndQueueMorePlayerActions | More player actions | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueMusicnowplayingpaneldetailsButton | Now Playing details | Music > Side panel > Now Playing | explained only | Mac | yes |
| control.music.playerAndQueueMusicplayerbarcompactbarKeyboardShortcut | Compact player bar controls | Music > Player bar | explained only | Mac | yes |
| control.music.playerAndQueueMusicplayerbarextrasButton | Mute and volume (player bar) | Music > Player bar | explained only | Mac | yes |
| control.music.playerAndQueueMusicplayerbartrackinfoButton | Like the playing song (heart) | Music > Player bar | explained only | Mac | yes |
| control.music.playerAndQueueMusicplayerbartransportButton | Shuffle and repeat (player bar) | Music > Player bar | explained only | Mac | yes |
| control.music.playerAndQueueMusicplayerbartransportKeyboardShortcut | Play or pause (player bar) | Music > Player bar | explained only | Mac | yes |
| control.music.playerAndQueueMusicsleepitemsbodyButton | A sleep timer choice | Music > Player bar > Sleep timer | explained only | Mac | yes |
| control.music.playerAndQueueNext | Next | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueOpenFullWindow | Open Full Window | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueOpenFullWindowNowPlaying | Open full-window Now Playing | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueOpenNowPlaying | Open Now Playing | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueuePlay | Play | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueuePrevious | Previous | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueQueue | Queue (player bar) | Music > Player bar | explained only | Mac | yes |
| control.music.playerAndQueueRemoveFromQueue | Remove from queue | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueRetryPlayingThisTrack | Retry playing this track | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueSleepTimer | Sleep timer | Music > Player and queue | explained only | Mac | yes |
| control.music.playerAndQueueUseFullPlayerBar | Use Full Player Bar | Music > Player and queue | explained only | Mac | yes |
| control.music.playerBarAudioQuality | Audio quality | Music > Player and queue | explained only | Mac | yes |
| control.music.playerBarMore | More player actions | Music > Player bar | destination music | Mac | yes |
| control.music.playerBarOutput | Output device | Music > Player and queue | explained only | Mac | yes |
| control.music.playerBarOutputDevice | Choose an output device | Music > Player and queue | explained only | Mac | yes |
| control.music.playerBarPill | Floating player bar | Music > Player bar | destination music | Mac | yes |
| control.music.playerBarVolumeStep | Volume up or down | Music > Player and queue | explained only | Mac | yes |
| control.music.playerHide | Hide player | Music > Player and queue | explained only | Mac | yes |
| control.music.playerHideShow | Hide or show the player bar | Music > Player bar | destination music | Mac | yes |
| control.music.playerRestore | Show player | Music > Player and queue | explained only | Mac | yes |
| control.music.playerStop | Stop playback | Music > Player and queue | explained only | Mac | yes |
| control.music.playerTimeToggle | Time left or total length | Music > Now Playing | explained only | Mac | no |
| control.music.playerWaveSeek | Drag the song position | Music > Player | explained only | Mac | no |
| control.music.playlistAddAllToPlaylist | Add all songs to another playlist | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistAddDescription | Add a description to a playlist | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistAddToQueue | Add the playlist to the queue | Music > Playlist | explained only | Mac | no |
| control.music.playlistChangeCover | Change the playlist cover | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistCover | Choose a playlist cover | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistDelete | Delete the playlist | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistDescriptionMore | Show more or less of a description | Music > Playlist | explained only | Mac | no |
| control.music.playlistDownload | Download the playlist | Music > Playlist | explained only | Mac | no |
| control.music.playlistDuplicate | Duplicate the playlist | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistEdit | Edit a playlist | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistEditDescription | Edit the playlist description | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistExport | Export a playlist | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistExportMenu | Export As menu | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistFindAnotherVersion | Find another version of a song | Music > Playlist | explained only | Mac | no |
| control.music.playlistIconButton | Playlist action button | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistImportCreate | Create playlist from the file | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistImportFile | Import a playlist file | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistMerge | Merge | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistMergeChoice | Playlist to merge with | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistMergeDelete | Remove the original playlists afterwards | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistMergeDrop | Leave out songs that appear more than once | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistMergeOpen | Merge with other playlists | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistMoreMenu | Playlist menu | Music > Playlist | explained only | Mac | no |
| control.music.playlistPlayNext | Play the playlist next | Music > Playlist | explained only | Mac | no |
| control.music.playlistRemoveRepeats | Remove repeated songs | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistRename | Rename the playlist | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistRepeatsOpen | Find repeated songs | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistShare | Share the playlist | Music > Playlist | explained only | Mac | no |
| control.music.playlistStatsOpen | Playlist statistics | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistSuggestionAdd | Add a suggested song | Music > Playlist | explained only | Mac | no |
| control.music.playlistSuggestionPlay | Play a suggested song | Music > Playlist | explained only | Mac | no |
| control.music.playlistSuggestionsRefresh | Show other suggestions | Music > Playlist | explained only | Mac | no |
| control.music.playlistTitleField | Playlist name field | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistTitleRename | Rename a playlist in place | Music > Your Library > Playlist | explained only | Mac | no |
| control.music.playlistToolsCancel | Cancel | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistToolsClose | Close | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.playlistViewAs | Choose how songs are drawn | Music > Playlist | explained only | Mac | no |
| control.music.playlistsCancel | Cancel | Music > Playlists | explained only | Mac | no |
| control.music.playlistsClose | Close | Music > Playlists | explained only | Mac | no |
| control.music.playlistsRemoveTheCoverPicture | Remove the cover picture | Music > Playlists | explained only | Mac | no |
| control.music.playlistsSave | Save | Music > Playlists | explained only | Mac | no |
| control.music.queueBackPrevious | Back to the previous queue | Music > Queue | explained only | Mac | no |
| control.music.queueJumpCurrent | Jump to the playing song in the queue | Music > Queue | explained only | Mac | no |
| control.music.queueKeepAuto | Keep an autoplay song | Music > Player and queue | explained only | Mac | yes |
| control.music.queueMoveBottom | Move a queue song to the bottom | Music > Queue | explained only | Mac | no |
| control.music.queueMoveDown | Move down | Music > Menus | explained only | Mac | no |
| control.music.queueMoveNext | Move to play next | Music > Menus | explained only | Mac | no |
| control.music.queueMoveUp | Move up | Music > Menus | explained only | Mac | no |
| control.music.queueOptionsMenu | Queue options menu | Music > Queue | explained only | Mac | no |
| control.music.queueRedo | Redo a queue change | Music > Queue | explained only | Mac | no |
| control.music.queueRemoveAutoplayGroup | Remove autoplay songs | Music > Queue | explained only | Mac | no |
| control.music.queueRestoreOrder | Restore the original queue order | Music > Queue | explained only | Mac | no |
| control.music.queueSaveAsPlaylist | Save the queue as a playlist | Music > Queue | explained only | Mac | no |
| control.music.queueSearchClear | Clear the queue search | Music > Queue | explained only | Mac | no |
| control.music.queueSearchToggle | Search the queue | Music > Queue | explained only | Mac | no |
| control.music.queueSelectAll | Select every upcoming song | Music > Queue | explained only | Mac | no |
| control.music.queueSelectDone | Finish selecting in the queue | Music > Queue | explained only | Mac | no |
| control.music.queueSelectRemove | Remove the selected songs | Music > Queue | explained only | Mac | no |
| control.music.queueSelectRow | Select this queue song | Music > Queue | explained only | Mac | no |
| control.music.queueSelectStart | Select songs in the queue | Music > Queue | explained only | Mac | no |
| control.music.queueSelectToPlaylist | Add the selected songs to a playlist | Music > Queue | explained only | Mac | no |
| control.music.queueStopAfter | Stop after this song | Music > Queue | explained only | Mac | no |
| control.music.queueStopAfterRow | Stop after this queue song | Music > Queue | explained only | Mac | no |
| control.music.queueUndo | Undo a queue change | Music > Queue | explained only | Mac | no |
| control.music.radioDelete | Delete a station | Music > Radio | explained only | Mac | no |
| control.music.radioDuplicate | Make a copy of a station | Music > Radio | explained only | Mac | no |
| control.music.radioEditAdd | Add the typed seed | Music > Radio > Edit station | explained only | Mac | no |
| control.music.radioEditAddField | Add to a station | Music > Radio > Edit station | explained only | Mac | no |
| control.music.radioEditDone | Finish editing a station | Music > Radio > Edit station | explained only | Mac | no |
| control.music.radioEditName | Station name | Music > Radio > Edit station | explained only | Mac | no |
| control.music.radioEditRemoveSeed | Stop following a seed | Music > Radio > Edit station | explained only | Mac | no |
| control.music.radioEditSeeds | Edit what a station follows | Music > Radio | explained only | Mac | no |
| control.music.radioEntityStart | Start radio from a name or film | Music > Radio > From names and films | explained only | Mac | no |
| control.music.radioMode | Station mode | Music > Radio | explained only | Mac | no |
| control.music.radioNew | New station | Music > Radio | explained only | Mac | no |
| control.music.radioNotForAWhile | Not for a while | Music > Radio > Player | explained only | Mac | no |
| control.music.radioNowArtist | Open the radio's artist | Music > Radio | explained only | Mac | no |
| control.music.radioNowCard | Now on radio card | Music > Radio | explained only | Mac | no |
| control.music.radioNowSong | Open the radio's song | Music > Radio | explained only | Mac | no |
| control.music.radioRegion | Radio country | Music > Radio > Country | explained only | Mac | yes |
| control.music.radioRename | Rename a station | Music > Radio | explained only | Mac | no |
| control.music.radioRetry | Try the station again | Music > Radio | explained only | Mac | no |
| control.music.radioSeedChip | Open what a station follows | Music > Radio | explained only | Mac | no |
| control.music.radioSeedClear | Clear the station field | Music > Radio | explained only | Mac | no |
| control.music.radioSeedField | Start a station field | Music > Radio | explained only | Mac | no |
| control.music.radioSeedStart | Start the typed station | Music > Radio | explained only | Mac | no |
| control.music.radioSeedSuggestion | Pick a station suggestion | Music > Radio | explained only | Mac | no |
| control.music.radioStart | Play a radio station | Music > Radio | explained only | Mac | no |
| control.music.radioStationCard | Play a station card | Music > Radio | explained only | Mac | no |
| control.music.radioStop | Stop radio | Music > Radio | explained only | Mac | no |
| control.music.radioThumb | Thumbs up and down | Music > Radio | explained only | Mac | no |
| control.music.radioThumbDown | Thumbs down | Music > Radio > Player | explained only | Mac | no |
| control.music.radioThumbUp | Thumbs up | Music > Radio > Player | explained only | Mac | no |
| control.music.ragaChoose | Choose raga | Music > Menus | explained only | Mac | no |
| control.music.ragaClose | Close | Music > Menus | explained only | Mac | no |
| control.music.ragaLanguage | Raga song language | Music > Menus | explained only | Mac | no |
| control.music.ragaMode | Film songs or Classical | Music > Menus | explained only | Mac | no |
| control.music.ragaPlaySong | Play raga song | Music > Menus | explained only | Mac | no |
| control.music.ragaSearch | Search ragas | Music > Menus | explained only | Mac | no |
| control.music.recapEarlier | Earlier recap | Music > Menus | explained only | Mac | no |
| control.music.recapLater | Later recap | Music > Menus | explained only | Mac | no |
| control.music.recapPeriod | Recap period | Music > Menus | explained only | Mac | no |
| control.music.recapPlay | Play this recap | Music > Menus | explained only | Mac | no |
| control.music.recentlyAddedRow | Recently added item | Music > Menus | explained only | Mac | no |
| control.music.relatedAlbumTrack | Play a song from the album | Music > Details panel > Related | explained only | Mac | no |
| control.music.relatedArtistFollow | Follow or unfollow the song's artist | Music > Details panel > Related | explained only | Mac | no |
| control.music.relatedArtistName | Open an artist by name | Music > Details panel > Related | explained only | Mac | no |
| control.music.relatedArtistRadio | Start radio from the song's artist | Music > Details panel > Related | explained only | Mac | no |
| control.music.relatedMoreFrom | More from a music director, lyricist or film | Music > Related | explained only | Mac | no |
| control.music.relatedOpenAlbum | Open the song's album | Music > Details panel > Related | explained only | Mac | no |
| control.music.relatedOpenArtist | Open the song's artist | Music > Details panel > Related | explained only | Mac | no |
| control.music.relatedSongRadio | Start a song radio | Music > Related | explained only | Mac | no |
| control.music.relatedVersions | Other versions and recordings | Music > Related | explained only | Mac | no |
| control.music.rowContextLink | Music director, film or actor link on a song row | Music > Song rows | explained only | Mac | no |
| control.music.searchArtistRow | Artist | Music > Search | explained only | Mac | no |
| control.music.searchBestMatchRadio | Start radio from the best match | Music > Search > Best match | explained only | Mac | no |
| control.music.searchClearRecentSearches | Clear recent searches | Music > Search | explained only | Mac | no |
| control.music.searchClearSearch | Clear search | Music > Search | explained only | Mac | no |
| control.music.searchDidYouMean | Did you mean | Music > Search | explained only | Mac | no |
| control.music.searchEntityFilter | Search type filter | Music > Search > Filters | explained only | Mac | no |
| control.music.searchField | Music search field | Music > Search | explained only | Mac | no |
| control.music.searchLoadMoreResults | Load more results | Music > Search | explained only | Mac | no |
| control.music.searchPlay | Play | Music > Search | explained only | Mac | no |
| control.music.searchRecent | Recent searches | Music > Search | destination music | Mac | yes |
| control.music.searchRemoveFromRecentSearches | Remove from recent searches | Music > Search | explained only | Mac | no |
| control.music.searchScope | Where to search | Music > Search | destination music | Mac | yes |
| control.music.searchScopeChoice | Where to search | Music > Menus | explained only | Mac | no |
| control.music.searchSearchFor | Search for | Music > Search | explained only | Mac | no |
| control.music.searchTrendingChip | Trending search | Music > Search | explained only | Mac | no |
| control.music.searchTypeChips | Search result types | Music > Search | destination music | Mac | yes |
| control.music.seeAll | See all results | Music > Search | explained only | Mac | no |
| control.music.settingsA11yHaptic | Trackpad tap for playback actions | Music > Menus | explained only | Mac | no |
| control.music.settingsA11yLarge | Large controls | Music > Menus | explained only | Mac | no |
| control.music.settingsA11yLimit | Loudest allowed volume | Music > Menus | explained only | Mac | no |
| control.music.settingsA11yLimitOn | Limit the volume | Music > Menus | explained only | Mac | no |
| control.music.settingsA11yNoVisualizer | Never show visualizers | Music > Menus | explained only | Mac | no |
| control.music.settingsA11yOverlay | Stronger text over pictures | Music > Menus | explained only | Mac | no |
| control.music.settingsA11ySimple | Simplified player | Music > Menus | explained only | Mac | no |
| control.music.settingsA11ySound | Sound for playback actions | Music > Menus | explained only | Mac | no |
| control.music.settingsAcoustIDConnect | Connect AcoustID | Music > Menus | explained only | Mac | no |
| control.music.settingsAcoustIDField | AcoustID key field | Music > Menus | explained only | Mac | no |
| control.music.settingsAcoustIDKey | AcoustID key | Music > Menus | explained only | Mac | no |
| control.music.settingsAcoustIDRemove | Remove AcoustID key | Music > Menus | explained only | Mac | no |
| control.music.settingsAcoustIDSave | Save AcoustID key | Music > Menus | explained only | Mac | no |
| control.music.settingsAudioTools | Audio tools | Music > Menus | explained only | Mac | no |
| control.music.settingsAutomation | Automation | Music > Menus | explained only | Mac | no |
| control.music.settingsAutomixClear | Clear | Music > Settings > Automix | explained only | Mac | no |
| control.music.settingsAutomixClearTheAnalysisCache | Clear the analysis cache | Music > Settings > Automix | explained only | Mac | no |
| control.music.settingsAutomixEqualizer | Equalizer | Music > Settings > Automix | explained only | Mac | no |
| control.music.settingsAutomixOpenTheEqualizer | Open the equalizer | Music > Settings > Automix | explained only | Mac | no |
| control.music.settingsClearSearch | Clear search | Music > Settings | explained only | Mac | no |
| control.music.settingsCloseSettings | Close settings | Music > Settings | explained only | Mac | no |
| control.music.settingsDataAndPrivacyCancel | Cancel | Music > Settings > Data and privacy | explained only | Mac | no |
| control.music.settingsDataAndPrivacyDeleteEverything | Delete everything | Music > Settings > Data and privacy | explained only | Mac | no |
| control.music.settingsDataAndPrivacyExportYourMusicLibrary | Export your music library | Music > Settings > Data and privacy | explained only | Mac | no |
| control.music.settingsDataAndPrivacyImportAMusicLibrary | Import a music library | Music > Settings > Data and privacy | explained only | Mac | no |
| control.music.settingsDetails | Details | Music > Settings | explained only | Mac | no |
| control.music.settingsDisclosure | More options | Music > Settings | explained only | Mac | no |
| control.music.settingsExtrasAddAMusicFolder | Add a music folder | Music > Settings > Extras | explained only | Mac | no |
| control.music.settingsExtrasCancel | Cancel | Music > Settings > Extras | explained only | Mac | no |
| control.music.settingsExtrasCheckPluginsForUpdates | Check plugins for updates | Music > Settings > Extras | explained only | Mac | no |
| control.music.settingsExtrasRemove | Remove | Music > Settings > Extras | explained only | Mac | no |
| control.music.settingsExtrasRescan | Rescan | Music > Settings > Extras | explained only | Mac | no |
| control.music.settingsExtrasRescanAll | Rescan all | Music > Settings > Extras | explained only | Mac | no |
| control.music.settingsExtrasStopScan | Stop scan | Music > Settings > Extras | explained only | Mac | no |
| control.music.settingsExtrasThoroughRescanOfAllFolders | Thorough rescan of all folders | Music > Settings > Extras | explained only | Mac | no |
| control.music.settingsExtrasUpdate | Update | Music > Settings > Extras | explained only | Mac | no |
| control.music.settingsFpcalc | Fingerprint tool | Music > Menus | explained only | Mac | no |
| control.music.settingsHiddenRecommendations | Hidden recommendations | Music > Menus | explained only | Mac | no |
| control.music.settingsLibraryHealth | Library health | Music > Menus | explained only | Mac | no |
| control.music.settingsListeningMode | Listening mode | Music > Menus | explained only | Mac | no |
| control.music.settingsMoreInformation | More information | Music > Settings | explained only | Mac | no |
| control.music.settingsMoveDown | Move down | Music > Settings | explained only | Mac | no |
| control.music.settingsMoveUp | Move up | Music > Settings | explained only | Mac | no |
| control.music.settingsMusicsettingspagerailrowButton | Settings tab | Music > Settings | explained only | Mac | yes |
| control.music.settingsMusicsettingspageresultrowButton | Settings search result | Music > Settings | explained only | Mac | yes |
| control.music.settingsMusicsourcerowbodyOnTapGesture | Music source row body click | Music > Settings | explained only | Mac | no |
| control.music.settingsMusicsourcerowbodyToggle | Music source row body Toggle | Music > Settings | explained only | Mac | no |
| control.music.settingsOwnInstanceRemoveYourOwnServerAddresses | Remove your own server addresses | Music > Settings > Own instance | explained only | Mac | no |
| control.music.settingsOwnInstanceTest | Test | Music > Settings > Own instance | explained only | Mac | no |
| control.music.settingsPauseOnDisconnect | Pause when headphones disconnect | Music > Menus | explained only | Mac | no |
| control.music.settingsPlaybackClearCache | Clear cache | Music > Settings > Playback | explained only | Mac | no |
| control.music.settingsPluginsSourcesAddAPlugin | Add a plugin | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesCancel | Cancel | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesClose | Close | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesHowPluginsWork | How plugins work | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesInstall | Install | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesInstallAPluginFromAFile | Install a plugin from a file | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesLogs | Logs | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesRemove | Remove | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesReviewPluginFromAddress | Review plugin from address | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesSaveAndSignIn | Save and sign in | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesSignOut | Sign out | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPluginsSourcesUpdate | Update | Music > Settings > Plugins & Sources | explained only | Mac | no |
| control.music.settingsPreferredArtists | Artists you like | Music > Menus | explained only | Mac | no |
| control.music.settingsPreferredGenres | Genres you like | Music > Menus | explained only | Mac | no |
| control.music.settingsPreferredLanguages | Languages you like | Music > Menus | explained only | Mac | no |
| control.music.settingsPrivateListening | Private listening | Music > Menus | explained only | Mac | no |
| control.music.settingsRedoSetup | Redo setup | Music > Menus | explained only | Mac | no |
| control.music.settingsResetConfirm | Confirm reset | Music > Menus | explained only | Mac | no |
| control.music.settingsResetRecommendations | Reset recommendations | Music > Menus | explained only | Mac | no |
| control.music.settingsResume | Remember my place | Music > Menus | explained only | Mac | no |
| control.music.settingsRolesMetadata | Metadata | Music > Settings > Roles | explained only | Mac | no |
| control.music.settingsRolesOpenScrobbling | Open scrobbling | Music > Settings > Roles | explained only | Mac | no |
| control.music.settingsRolesOpenTheLyricsSources | Open the lyrics sources | Music > Settings > Roles | explained only | Mac | no |
| control.music.settingsScrobblingAddACleanupRule | Add a cleanup rule | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingCancel | Cancel | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingCancelLastFmSignIn | Cancel Last.fm sign-in | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingConnectLastFm | Connect Last.fm | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingConnectListenbrainz | Connect ListenBrainz | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingDisconnectLastFm | Disconnect Last.fm | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingDisconnectListenbrainz | Disconnect ListenBrainz | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingEditWhatThisTrackScrobblesAs | Edit what this track scrobbles as | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingEmptyRule | Empty rule | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingField | Field | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingMusicscrobblesettingssectioncleanupButton | Scrobble cleanup rules | Music > Settings > Plugins & Sources > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingMusicscrobblesettingssectionrulerowButton | A scrobble cleanup rule | Music > Settings > Plugins & Sources > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingOn | On | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingOpenListenbrainzSettings | Open ListenBrainz settings | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingOpenProfile | Open profile | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingRemoveEdit | Remove edit | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingRemoveTheEditForThisTrack | Remove the edit for this track | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingSave | Save | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsScrobblingVerifyYourMetabrainzEmail | Verify your MetaBrainz email | Music > Settings > Scrobbling | explained only | Mac | yes |
| control.music.settingsSearch | Search Music settings | Music > Settings | explained only | Mac | no |
| control.music.settingsSeekBack | Skip back length | Music > Menus | explained only | Mac | no |
| control.music.settingsSeekForward | Skip forward length | Music > Menus | explained only | Mac | no |
| control.music.settingsShortcutsCancelRecording | Cancel recording | Music > Settings > Playback > Player > Global hotkeys | explained only | Mac | yes |
| control.music.settingsShortcutsClear | Clear | Music > Settings > Playback > Player > Global hotkeys | explained only | Mac | yes |
| control.music.settingsShortcutsUseDefault | Use default | Music > Settings > Playback > Player > Global hotkeys | explained only | Mac | yes |
| control.music.settingsSonic | Sound analysis | Music > Menus | explained only | Mac | no |
| control.music.settingsSonicForget | Forget analysis | Music > Menus | explained only | Mac | no |
| control.music.settingsSonicToggle | Sound analysis switch | Music > Menus | explained only | Mac | no |
| control.music.settingsTidyDuplicates | Find repeated songs | Music > Menus | explained only | Mac | no |
| control.music.settingsTidyMissing | Check for missing files | Music > Menus | explained only | Mac | no |
| control.music.settingsWatchFolders | Watch folders for changes | Music > Menus | explained only | Mac | no |
| control.music.settingsYourMusicServerAddTheMusicServer | Add the music server | Music > Settings > Your music server | explained only | Mac | no |
| control.music.settingsYourMusicServerRemove | Remove | Music > Settings > Your music server | explained only | Mac | no |
| control.music.settingsYourMusicServerTest | Test | Music > Settings > Your music server | explained only | Mac | no |
| control.music.settingsYourMusicServerTestTheServerDetails | Test the server details | Music > Settings > Your music server | explained only | Mac | no |
| control.music.setupArtist | Pick an artist | Music > Menus | explained only | Mac | no |
| control.music.setupArtistSearch | Add an artist | Music > Menus | explained only | Mac | no |
| control.music.setupBack | Back | Music > Menus | explained only | Mac | no |
| control.music.setupCardDismiss | Not now | Music > Menus | explained only | Mac | no |
| control.music.setupCardOpen | Set up | Music > Menus | explained only | Mac | no |
| control.music.setupContinue | Continue Music setup | Music > Set up | explained only | Mac | no |
| control.music.setupCustomize | Choose sources myself | Music > Set up | explained only | Mac | no |
| control.music.setupExtra | Optional extra | Music > Menus | explained only | Mac | no |
| control.music.setupFolder | Choose a music folder in setup | Music > Menus | explained only | Mac | no |
| control.music.setupGenre | Genre | Music > Menus | explained only | Mac | no |
| control.music.setupGenreLike | Like this genre | Music > Menus | explained only | Mac | no |
| control.music.setupGenreLove | Love this genre | Music > Menus | explained only | Mac | no |
| control.music.setupGenreNo | Not for me | Music > Menus | explained only | Mac | no |
| control.music.setupGroupButtons | Select recommended or turn all off | Music > Set up > Customize | explained only | Mac | no |
| control.music.setupNext | Continue or Done | Music > Menus | explained only | Mac | no |
| control.music.setupShared | What is shared | Music > Set up | explained only | Mac | no |
| control.music.setupSkip | Skip setup | Music > Menus | explained only | Mac | no |
| control.music.setupSonic | Sound analysis in setup | Music > Menus | explained only | Mac | no |
| control.music.setupSource | Music source switch | Music > Set up > Choose sources | explained only | Mac | no |
| control.music.share | Share a song, album, artist or playlist | Music > Menu | explained only | Mac | no |
| control.music.shareClose | Close | Music > Share | explained only | Mac | no |
| control.music.shareCopyLink | Copy link | Music > Share | explained only | Mac | no |
| control.music.sharePublic | Public | Music > Share | explained only | Mac | no |
| control.music.shareShare | Share | Music > Share | explained only | Mac | no |
| control.music.shareStartAt | Start at | Music > Share | explained only | Mac | no |
| control.music.sharedPartsClose | Close | Music > Shared parts | explained only | Mac | no |
| control.music.sharedPartsMoreActionsFor | More actions for | Music > Shared parts | explained only | Mac | no |
| control.music.sharedPartsMusiccardbodyContextMenu | Music card body context menu | Music > Shared parts | explained only | Mac | no |
| control.music.sharedPartsMusiccardcardButton | A card | Music > Cards | explained only | Mac | yes |
| control.music.sharedPartsMusicchipbodyButton | A chip | Music > Pages | explained only | Mac | yes |
| control.music.sharedPartsMusicemptystatebodyButton | Empty page action | Music > Pages | explained only | Mac | yes |
| control.music.sharedPartsMusicinlinelinkbodyButton | A name that is a link | Music > Links | explained only | Mac | yes |
| control.music.sharedPartsMusictrackrowbodyButton | A song row | Music > Song lists | explained only | Mac | yes |
| control.music.sharedPartsMusictrackrowbodyContextMenu | Music track row body context menu | Music > Shared parts | explained only | Mac | no |
| control.music.sharedPartsMusictrackrowbodyOnTapGesture | Music track row body click | Music > Shared parts | explained only | Mac | no |
| control.music.sharedPartsPlay | Play | Music > Shared parts | explained only | Mac | no |
| control.music.sheetFieldClear | Clear the search box | Music > Menus | explained only | Mac | no |
| control.music.shelfPageBack | Previous cards in a shelf | Music > Shelves | explained only | Mac | no |
| control.music.shelfPageForward | Next cards in a shelf | Music > Shelves | explained only | Mac | no |
| control.music.shelfSeeAll | See all of a shelf | Music > Shelves | explained only | Mac | no |
| control.music.showAll | Show all in a shelf | Music > Shelves | explained only | Mac | no |
| control.music.shuffleMode | Shuffle style | Music > Player and queue | explained only | Mac | yes |
| control.music.shuffleQueueMenu | Shuffle options in the queue | Music > Player and queue | explained only | Mac | yes |
| control.music.shuffleReshuffle | Reshuffle | Music > Player and queue | explained only | Mac | yes |
| control.music.sidePanelButton | Side panel button | Music > Page top right | destination music | Mac | yes |
| control.music.sidebar | Music sidebar | Music > Sidebar | explained only | Mac | yes |
| control.music.sidebarFold | Fold a sidebar group | Music > Sidebar | destination music | Mac | yes |
| control.music.sidebarNewPlaylist | Create a new playlist from the sidebar | Music > Sidebar > Playlists | explained only | Mac | no |
| control.music.sidebarNowPlaying | Now playing card | Music > Sidebar | explained only | Mac | yes |
| control.music.sidebarOpenLink | Open a Link (sidebar) | Music > Sidebar > More > Open a Link | destination music | Mac | yes |
| control.music.sidebarRecent | Recently played album | Music > Sidebar | explained only | Mac | yes |
| control.music.sidebarToggle | Keep the Music sidebar open or auto-hide it | Music > Sidebar | explained only | Mac | yes |
| control.music.sleepTimerMusic | Music sleep timer | Music > Player bar > Sleep timer | destination music | Mac | yes |
| control.music.smartAddRule | Add a rule | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartChipMenu | Smart playlist menu | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartDelete | Delete a smart playlist | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartDuplicate | Duplicate a smart playlist | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartEdit | Edit a smart playlist | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartField | Rule field | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartKeep | Keep as playlist | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartMatch | Match all or any rule | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartNew | New smart playlist | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartOperator | Rule comparison | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartPlaylistHide | Hide a smart playlist | Music > Your library > Playlists > Made for you | explained only | Mac | no |
| control.music.smartPlaylistSave | Save a smart playlist as a playlist | Music > Your library > Playlists > Made for you | explained only | Mac | no |
| control.music.smartRedraw | Draw again | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartRemoveRule | Remove a rule | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartSave | Save a smart playlist | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.smartSort | Smart playlist sort | Music > Your Library > Playlists | explained only | Mac | no |
| control.music.songInfoRaga | Raga | Music > Menus | explained only | Mac | no |
| control.music.songListsClearFilter | Clear filter | Music > Song lists | explained only | Mac | no |
| control.music.songListsMusictracklistcolumnmenuToggle | Music track list column menu Toggle | Music > Song lists | explained only | Mac | no |
| control.music.songListsMusictracklisttoolbuttonButton | Song list tool button | Music > Song lists | explained only | Mac | yes |
| control.music.songListsMusictracklisttoolsKeyboardShortcut | Keys for song lists | Music > Song lists | explained only | Mac | yes |
| control.music.songListsSortBy | Sort by | Music > Song lists | explained only | Mac | no |
| control.music.songListsSwitchToDescending | Switch to descending | Music > Song lists | explained only | Mac | no |
| control.music.songMenusAddAnyway | Add anyway (duplicates) | Music > Song menus > Add to playlist | explained only | Mac | yes |
| control.music.songMenusAddToPlaylist | Add to Playlist | Music > Song menus | explained only | Mac | no |
| control.music.songMenusAddToQueue | Add to Queue | Music > Song menus | explained only | Mac | no |
| control.music.songMenusAllowAgain | Allow Again | Music > Song menus | explained only | Mac | no |
| control.music.songMenusAllowThisTrackAgain | Allow This Track Again | Music > Song menus | explained only | Mac | no |
| control.music.songMenusBack | Back | Music > Song menus | explained only | Mac | no |
| control.music.songMenusCancelSelection | Cancel selection | Music > Song menus | explained only | Mac | no |
| control.music.songMenusChooseAnotherAudioSource | Choose Another Audio Source | Music > Song menus | explained only | Mac | no |
| control.music.songMenusClear | Clear | Music > Song menus | explained only | Mac | no |
| control.music.songMenusClose | Close | Music > Song menus | explained only | Mac | no |
| control.music.songMenusConvert | Convert | Music > Menus | explained only | Mac | no |
| control.music.songMenusDownload | Download | Music > Song menus | explained only | Mac | no |
| control.music.songMenusEditDetails | Edit song details | Music > Menus | explained only | Mac | no |
| control.music.songMenusEditScrobble | Edit Scrobble | Music > Song menus | explained only | Mac | no |
| control.music.songMenusFindCredits | Find film and music director | Music > Song menu > Go to | explained only | Mac | no |
| control.music.songMenusFindMissingDetails | Find missing details | Music > Menus | explained only | Mac | no |
| control.music.songMenusGoTo | Go to | Music > Song menus | explained only | Mac | no |
| control.music.songMenusGoToConnected | Go to a connected page | Music > Song menu > Go to | explained only | Mac | no |
| control.music.songMenusGoToMenu | Go to | Music > Song menu > Go to | explained only | Mac | no |
| control.music.songMenusGoToSong | Go to Song | Music > Song menus | explained only | Mac | no |
| control.music.songMenusHideArtist | Hide songs by this artist | Music > Menus | explained only | Mac | no |
| control.music.songMenusHideRecommendation | Hide recommendation | Music > Menus | explained only | Mac | no |
| control.music.songMenusHideSong | Hide this song | Music > Menus | explained only | Mac | no |
| control.music.songMenusIdentifyBySound | Identify by sound | Music > Menus | explained only | Mac | no |
| control.music.songMenusInYourLibrary | In Your Library | Music > Song menus | explained only | Mac | no |
| control.music.songMenusLockFile | Lock file against changes | Music > Menus | explained only | Mac | no |
| control.music.songMenusMinusCircle | Never Play This Track | Music > Song menus | explained only | Mac | yes |
| control.music.songMenusMusicaddtoplaylistsheetpickButton | Pick a playlist to add to | Music > Song menus > Add to playlist | explained only | Mac | yes |
| control.music.songMenusMusicselectionbarbodyButton | Selection bar actions | Music > Song lists > Selection | explained only | Mac | yes |
| control.music.songMenusMusicselectionbariconButton | Selection bar icon actions | Music > Song lists > Selection | explained only | Mac | yes |
| control.music.songMenusNewPlaylist | New Playlist | Music > Song menus | explained only | Mac | no |
| control.music.songMenusPlay | Play | Music > Song menus | explained only | Mac | no |
| control.music.songMenusPlayNext | Play Next | Music > Song menus | explained only | Mac | no |
| control.music.songMenusRemoveDislike | Remove Dislike | Music > Song menus | explained only | Mac | no |
| control.music.songMenusRemoveFromLibrary | Remove from Library | Music > Song menus | explained only | Mac | no |
| control.music.songMenusRemoveFromLikedSongs | Remove from Liked Songs | Music > Song menus | explained only | Mac | no |
| control.music.songMenusRemoveFromThisPlaylist | Remove from This Playlist | Music > Song menus | explained only | Mac | no |
| control.music.songMenusSaveToYourLibrary | Save to Your Library | Music > Song menus | explained only | Mac | no |
| control.music.songMenusSelectAll | Select all | Music > Song menus | explained only | Mac | no |
| control.music.songMenusShare | Share | Music > Song menus | explained only | Mac | no |
| control.music.songMenusShuffle | Shuffle | Music > Song menus | explained only | Mac | no |
| control.music.songMenusSkipDuplicates | Skip duplicates | Music > Song menus > Add to playlist | explained only | Mac | yes |
| control.music.songMenusSongInformation | Song information | Music > Menus | explained only | Mac | no |
| control.music.songMenusSoundsLike | Sounds Like | Music > Menus | explained only | Mac | no |
| control.music.songMenusStartRadio | Start Radio | Music > Song menus | explained only | Mac | no |
| control.music.songMenusSuggestToRoom | Suggest to Room | Music > Song menus | explained only | Mac | no |
| control.music.songMenusTempoPitchAndReverb | Tempo, Pitch and Reverb | Music > Song menus | explained only | Mac | no |
| control.music.songMenusTrackMarks | Loop, Bookmarks and Skips | Music > Menus | explained only | Mac | no |
| control.music.songMenusUnblock | Unblock | Music > Song menus | explained only | Mac | no |
| control.music.songMenusViewCredits | View credits | Music > Menus | explained only | Mac | no |
| control.music.songMenusViewLyrics | View lyrics | Music > Menus | explained only | Mac | no |
| control.music.songMenusVisualizer | Visualizer | Music > Menus | explained only | Mac | no |
| control.music.songPageAddToQueue | Add this song to the queue | Music > Song page | explained only | Mac | no |
| control.music.songPageAlbum | Open the song's album | Music > Song page | explained only | Mac | no |
| control.music.songPageCard | Open a related song or film | Music > Song page | explained only | Mac | no |
| control.music.songPageFilm | Open the song's film | Music > Song page | explained only | Mac | no |
| control.music.songPageFindCopy | Find a playable copy | Music > Song page | explained only | Mac | no |
| control.music.songPageLike | Like this song | Music > Song page | explained only | Mac | no |
| control.music.songPageLyricsExpand | Show all lyrics | Music > Song page | explained only | Mac | no |
| control.music.songPageLyricsSearch | Search for lyrics again | Music > Song page | explained only | Mac | no |
| control.music.songPageMore | More ways to play this song | Music > Song page | explained only | Mac | no |
| control.music.songPageOriginal | Open the original recording | Music > Song page | explained only | Mac | no |
| control.music.songPagePerson | Open a credited person | Music > Song page | explained only | Mac | no |
| control.music.songPagePlay | Play this song | Music > Song page | explained only | Mac | no |
| control.music.songPagePlayFromSource | Play from a source | Music > Song page | explained only | Mac | no |
| control.music.songPagePlayNext | Play this song next | Music > Song page | explained only | Mac | no |
| control.music.songPagePlaylist | Open a playlist that holds the song | Music > Song page | explained only | Mac | no |
| control.music.songPageSample | Sampled song | Music > Menus | explained only | Mac | no |
| control.music.songPageStartRadio | Start radio from this song | Music > Song | explained only | Mac | no |
| control.music.songPageVersion | Open another version of the song | Music > Song page | explained only | Mac | no |
| control.music.sonicClose | Close | Music > Menus | explained only | Mac | no |
| control.music.sonicEnergy | Energy direction | Music > Menus | explained only | Mac | no |
| control.music.sonicJourneyChange | Choose another destination | Music > Menus | explained only | Mac | no |
| control.music.sonicJourneyPick | Pick the destination | Music > Menus | explained only | Mac | no |
| control.music.sonicJourneySearch | Search the destination | Music > Menus | explained only | Mac | no |
| control.music.sonicMode | Sounds Like mode | Music > Menus | explained only | Mac | no |
| control.music.sonicPlay | Play song | Music > Menus | explained only | Mac | no |
| control.music.sonicPlayAll | Play all | Music > Menus | explained only | Mac | no |
| control.music.soundcloudChapter | Jump to a chapter of a mix | Music > Now Playing > Chapters | explained only | Mac | no |
| control.music.soundcloudMoreShelf | More uploads by the artist | Music > Artist page | explained only | Mac | no |
| control.music.soundtrackAddToPlaylist | Add album to a playlist | Music > Album | explained only | Mac | no |
| control.music.soundtrackExploreLink | Continue exploring | Music > Album | explained only | Mac | no |
| control.music.soundtrackFavourite | Save album to Your library | Music > Album | explained only | Mac | no |
| control.music.soundtrackFilmChip | Film of this soundtrack | Music > Album | explained only | Mac | no |
| control.music.soundtrackShare | Share album | Music > Album | explained only | Mac | no |
| control.music.soundtrackSongDetails | Song details | Music > Album | explained only | Mac | no |
| control.music.soundtrackSongRow | Play a song of the album | Music > Album | explained only | Mac | no |
| control.music.soundtrackSongsRetry | Try loading the rest of the songs | Music > Album | explained only | Mac | no |
| control.music.soundtrackViewFilm | View film | Music > Album | explained only | Mac | no |
| control.music.sources | Added audio sources | Music > Settings > Plugins & Sources > Added sources | explained only | Mac | yes |
| control.music.sourcesAddThisAddon | Add this addon | Music > Sources | explained only | Mac | no |
| control.music.sourcesAddonQuality | Addon quality | Music > Sources | explained only | Mac | no |
| control.music.sourcesCancel | Cancel | Music > Sources | explained only | Mac | no |
| control.music.sourcesRemove | Remove a source | Music > Settings > Plugins & Sources > Added sources | explained only | Mac | yes |
| control.music.sourcesTest | Test | Music > Sources | explained only | Mac | no |
| control.music.sourcesTestThisAddressWithoutSaving | Test this address without saving | Music > Sources | explained only | Mac | no |
| control.music.stationMode | Choose station mode | Music > Menus | explained only | Mac | no |
| control.music.stationModeMenu | Station mode | Music > Menus | explained only | Mac | no |
| control.music.stationRetry | Try the station again | Music > Menus | explained only | Mac | no |
| control.music.stationStop | Stop station | Music > Menus | explained only | Mac | no |
| control.music.statistics01 | A ranked item in Music statistics | Statistics > Music | explained only | Mac | yes |
| control.music.statisticsClearListeningHistory | Clear Listening History | Music > Statistics | explained only | Mac | no |
| control.music.statisticsMusicstatsviewtopartistsButton | A top artist in Music statistics | Statistics > Music | explained only | Mac | yes |
| control.music.statisticsPlays | plays | Music > Statistics | explained only | Mac | no |
| control.music.statisticsRange | Range | Music > Statistics | explained only | Mac | no |
| control.music.subsonicAdd | Add a music server | Music > Settings > Plugins & Sources > Your music server | explained only | Mac | no |
| control.music.subsonicConvert | Convert audio on the music server | Music > Settings > Plugins & Sources > Your music server | explained only | Mac | no |
| control.music.subsonicOwnNetwork | This is my own server on my network | Music > Settings > Plugins & Sources > Your music server | explained only | Mac | no |
| control.music.subsonicRemove | Remove a music server | Music > Settings > Plugins & Sources > Your music server | explained only | Mac | no |
| control.music.subsonicTest | Test a music server | Music > Settings > Plugins & Sources > Your music server | explained only | Mac | no |
| control.music.subsonicUse | Use my music server | Music > Settings > Plugins & Sources > Your music server | explained only | Mac | no |
| control.music.suggestFill | Put a suggestion in the search field | Music > Search | explained only | Mac | no |
| control.music.suggestSearch | Search the typed words | Music > Search | explained only | Mac | no |
| control.music.theatreClose | Close | Music > Theatre | explained only | Mac | no |
| control.music.theatreCloseTheatreMode | Close theatre mode | Music > Theatre | explained only | Mac | no |
| control.music.theatreLyricsColumn | Lyrics column | Music > Theatre | explained only | Mac | no |
| control.music.theatreMusictheatreviewdockButton | Theatre controls | Music > Theatre | explained only | Mac | yes |
| control.music.theatreMusictheatreviewstageButton | Theatre stage | Music > Theatre | explained only | Mac | yes |
| control.music.theatreNext | Next | Music > Theatre | explained only | Mac | no |
| control.music.theatrePrevious | Previous | Music > Theatre | explained only | Mac | no |
| control.music.theatreQueueColumn | Queue column | Music > Theatre | explained only | Mac | no |
| control.music.theatreRepeat | Repeat | Music > Theatre | explained only | Mac | no |
| control.music.theatreShuffle | Shuffle | Music > Theatre | explained only | Mac | no |
| control.music.thoroughRescan | Thorough rescan of local folders | Music > Settings > Local folders | explained only | Mac | no |
| control.music.tidyClose | Close | Music > Menus | explained only | Mac | no |
| control.music.tidyKeepBest | Keep best | Music > Menus | explained only | Mac | no |
| control.music.tidyLocate | Locate | Music > Menus | explained only | Mac | no |
| control.music.tidyRemoveAllExtras | Remove all extras | Music > Menus | explained only | Mac | no |
| control.music.tidyRemoveMissing | Remove missing song | Music > Menus | explained only | Mac | no |
| control.music.tidyTab | Tidy tab | Music > Menus | explained only | Mac | no |
| control.music.topResultPlay | Play the top result | Music > Search | explained only | Mac | no |
| control.music.topResultRadio | Start radio from the top result | Music > Search | explained only | Mac | no |
| control.music.trackSheetClose | Close | Music > Menus | explained only | Mac | no |
| control.music.visualizerClose | Close visualizer | Music > Menus | explained only | Mac | no |
| control.music.visualizerColour | Visualizer colours | Music > Menus | explained only | Mac | no |
| control.music.visualizerFPS | Visualizer frame rate | Music > Menus | explained only | Mac | no |
| control.music.visualizerFullScreen | Visualizer full screen | Music > Menus | explained only | Mac | no |
| control.music.visualizerMode | Visualizer look | Music > Menus | explained only | Mac | no |
| control.music.visualizerPreset | Visualizer preset | Music > Menus | explained only | Mac | no |
| control.music.visualizerPresets | Visualizer presets | Music > Menus | explained only | Mac | no |
| control.music.visualizerSecondDisplay | Visualizer on the other display | Music > Menus | explained only | Mac | no |
| control.music.visualizerSensitivity | Visualizer sensitivity | Music > Menus | explained only | Mac | no |
| control.music.visualizerSmoothing | Visualizer smoothness | Music > Menus | explained only | Mac | no |
| control.music.wheelFilm | Movie on the connection wheel | Music > Menus | explained only | Mac | no |
| control.music.wheelPeople | People on the connection wheel | Music > Menus | explained only | Mac | no |
| control.music.wheelPerson | Person on the connection wheel | Music > Menus | explained only | Mac | no |
| control.music.wheelPersonChoice | Choose a person | Music > Menus | explained only | Mac | no |
| control.music.yourLibraryCancel | Cancel | Music > Your Library | explained only | Mac | no |
| control.music.yourLibraryCreate | Create | Music > Your Library | explained only | Mac | no |
| control.music.yourLibraryCreateAPlaylist | Create a playlist | Music > Your Library | explained only | Mac | no |
| control.music.yourLibraryExportABackupOfYourMusic | Export a backup of your music library | Music > Your Library | explained only | Mac | no |
| control.music.yourLibraryImportABackupOfYourMusic | Import a backup of your music library | Music > Your Library | explained only | Mac | no |
| control.music.yourLibraryOpenTheListOfSongsAnd | Open the list of songs and artists you never want to hear | Music > Your Library | explained only | Mac | no |
| control.nav.the external service | the external service tab | Top bar | explained only | Mac | no |
| control.nav.searchIcon | Search icon | Top bar | explained only | Mac | no |
| control.nav.service | Service tab | Top bar | explained only | Mac | no |
| control.nav.service.reload | Reload a service | Top bar | explained only | Mac | no |
| control.nav.streamsetu | StreamSetu item | Top bar | explained only | Mac | no |
| control.nav.tabMode | Top bar item style | Top bar | explained only | Mac | no |
| control.the external service.dismissNotice | Dismiss notice (the external service) | the external service | explained only | Mac | no |
| control.the external service.openBlocked | Open blocked link in browser | the external service | explained only | Mac | no |
| control.the external service.openBrowser | Open in Default Browser (the external service) | the external service | explained only | Mac | no |
| control.the external service.retry | Try Again (the external service) | the external service | explained only | Mac | no |
| control.onboarding.skip | Skip for now | First run | explained only | Mac | no |
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
| control.player.privateBadge | Private viewing indicator | Player | explained only | Mac, iPhone, iPad | yes |
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
| control.podcasts.category | Podcast categories | Podcasts > Discover | explained only | Mac | yes |
| control.podcasts.follow | Follow or unfollow a podcast | Files and Servers > Podcasts | explained only | Mac | yes |
| control.podcasts.myCategory | Your podcast category | Podcasts | explained only | Mac | no |
| control.podcasts.nowPlaying | Podcast Now Playing panel | Podcasts > Player | explained only | Mac | yes |
| control.podcasts.play | Play a podcast episode | Files and Servers > Podcasts | explained only | Mac | yes |
| control.podcasts.player | Podcast player controls | Podcasts > Player | explained only | Mac | yes |
| control.podcasts.queue | Podcast Up Next | Podcasts > Up Next | explained only | Mac | yes |
| control.podcasts.search | Search podcasts | Podcasts > Discover | explained only | Mac | yes |
| control.podcasts.sleep | Podcast sleep timer | Podcasts > Player | explained only | Mac | yes |
| control.podcasts.sort | Sort podcast episodes | Podcasts > Show | explained only | Mac | yes |
| control.podcasts.speed | Podcast speed and skips | Podcasts > Player | explained only | Mac | yes |
| control.profiles.add | Add a profile, PIN to open it, Kids profile | Settings > Library > Profiles > Add | settings page Library | Mac, iPhone, iPad | yes |
| control.profiles.remove | Remove a profile | Settings > Library > Profiles | settings page Library | Mac, iPhone, iPad | yes |
| control.search.askAI | Ask AI for picks | Search | explained only | Mac, iPhone, iPad | yes |
| control.search.askSetuRow | Ask Setu row in the search results | Top bar > Search > Ask Setu row | explained only | Mac | yes |
| control.search.idea | Search ideas | Search | explained only | Mac, iPhone, iPad | yes |
| control.search.topBar | Search or ask Setu (top search box) | Top bar > Search | explained only | Mac | yes |
| control.series.seasonPicker | Season picker | Series > Title page | explained only | Mac | yes |
| control.service.authPopupClose | Close sign-in window | Services | explained only | Mac | no |
| control.service.dismissNotice | Dismiss notice (service) | Services | explained only | Mac | no |
| control.service.hideElement | Hide This Element (service page) | Services | explained only | Mac | no |
| control.service.hideElementButton | Hide an element on the page | Services | explained only | Mac | no |
| control.service.openBlocked | Open blocked link in browser | Services | explained only | Mac | no |
| control.service.openBrowser | Open in Default Browser (service) | Services | explained only | Mac | no |
| control.service.retry | Try Again (service) | Services | explained only | Mac | no |
| control.service.returnHome | Return to StreamSetu | Services | explained only | Mac | no |
| control.service.undoHide | Undo hiding an element | Services | explained only | Mac | no |
| control.services.clearData | Clear a service's data (top bar) | Top bar | explained only | Mac | no |
| control.services.filter | Filter services | Top bar > Services | explained only | Mac | no |
| control.services.menu | Services menu | Top bar | explained only | Mac | no |
| control.services.move | Move a pinned service | Top bar | explained only | Mac | no |
| control.services.open | Open a service | Top bar > Services | explained only | Mac | no |
| control.services.pillmenu | Service pill menu | Top bar | explained only | Mac | no |
| control.services.pin | Pin or unpin a service | Top bar > Services | explained only | Mac | no |
| control.services.section | Services list section | Top bar > Services | explained only | Mac | no |
| control.settings.artworkTrending | Use the movie database weekly trending | Settings > Library > Artwork and details | explained only | Mac | yes |
| control.settings.askSetu | Ask Setu (Settings header) | Settings > Ask Setu | explained only | Mac | yes |
| control.settings.backupContents | What a backup contains | Settings > Library > Backup | explained only | Mac | yes |
| control.settings.checkForUpdates | Check for updates | Settings > Advanced > About | explained only | Mac | yes |
| control.settings.clearArtworkCache | Clear artwork cache | Settings > Advanced > Reset | explained only | Mac | yes |
| control.settings.clearHistory | Clear viewing history | Settings > Advanced > Reset | explained only | Mac | yes |
| control.settings.clearSearchHistory | Clear search history | Settings > Library > Search index | explained only | Mac | yes |
| control.settings.copyReport | Copy diagnostics report | Settings > Advanced > Diagnostics | explained only | Mac | yes |
| control.settings.crashReports | Crash reports | Settings > Advanced > About | explained only | Mac | yes |
| control.settings.enhancementAdSkip | Skip ads (page option) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.enhancementHideAds | Hide ads and upgrade prompts (page option) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.enhancementMuteAds | Mute audio ads (page option) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.enhancementPromptReset | Show the first-open prompt again | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.enhancementReload | Reload to apply page options (Settings) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.enhancementSponsorSkip | Skip sponsor segments (page option) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.hiddenElementsReset | Reset hidden elements (per service) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.icloudErase | Erase iCloud data | Settings > General > iCloud | explained only | Mac | yes |
| control.settings.icloudSyncNow | Sync with iCloud now | Settings > General > iCloud | explained only | Mac | yes |
| control.settings.lanAddDevice | Add a device to sync with | Settings > General > Sync on this network | explained only | Mac | yes |
| control.settings.lanForget | Forget a paired device | Settings > General > Sync on this network | explained only | Mac | yes |
| control.settings.lanPairConfirm | Confirm pairing | Settings > General > Sync on this network | explained only | Mac | yes |
| control.settings.lanPairDevice | Pair with a nearby device | Settings > General > Sync on this network | explained only | Mac | yes |
| control.settings.lanSyncNow | Sync on this network now | Settings > General > Sync on this network | explained only | Mac | yes |
| control.settings.moreSources | More sources | Settings > Library > More sources | explained only | Mac | yes |
| control.settings.openNetworkSettings | Open Network Settings (Local Network) | Settings > Privacy | settings page Privacy | Mac | yes |
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
| control.settings.servicesKeepPlaying | Keep services playing in the background | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesMove | Move a service (Settings) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesOpen | Open a service (Settings) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesPin | Pin a service (Settings) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesReset | Reset the top row order | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.servicesRow | Streaming service row | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.showDataFolder | Show data folder | Settings > Advanced > About | explained only | Mac | yes |
| control.settings.testTmdbKey | Test the the movie database key | Settings > Library > Artwork and details | explained only | Mac | yes |
| control.settings.tidyPages | Tidy pages (per service) | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.topBarReset | Reset top bar to defaults | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.settings.topBarTabs | Top bar item styles | Settings > Privacy > Streaming services | explained only | Mac | no |
| control.setu.answerButtons | Buttons under a Setu answer | Setu | explained only | Mac, iPhone, iPad | yes |
| control.setu.modelMenu | Setu engine menu and Allow online AI services | Setu > Engine menu | settings page Library | Mac, iPhone, iPad | yes |
| control.setu.newChat | Start a new chat with Setu | Setu > New chat | explained only | Mac, iPhone, iPad | yes |
| control.setu.shareScreen | Share my screen with Setu (eye button) | Setu > Eye button | explained only | Mac, iPhone, iPad | yes |
| control.setu.starterChips | Setu starter questions | Setu | explained only | Mac, iPhone, iPad | yes |
| control.setup.back | Back to the previous step | Help > Get Set Up | explained only | Mac | no |
| control.setup.done | Save Get Set Up | Help > Get Set Up | explained only | Mac | no |
| control.setup.music | Set up Music when I finish | Help > Get Set Up | explained only | Mac | no |
| control.setup.musicLater | Set up Music later | Help > Get Set Up | explained only | Mac | no |
| control.setup.next | Continue to the next step | Help > Get Set Up | explained only | Mac | no |
| control.setup.notNow | Skip Get Set Up | Help > Get Set Up | explained only | Mac | no |
| control.setup.podcastGenre | Podcast category | Help > Get Set Up | explained only | Mac | no |
| control.setup.podcastRegion | Podcast charts region | Help > Get Set Up | explained only | Mac | no |
| control.setup.service | Pin a streaming service | Help > Get Set Up | explained only | Mac | no |
| control.shelf.scrollArrow | Shelf arrows | Home > Shelves | explained only | Mac | yes |
| control.sidebar.collapse | Collapse the sidebar | Sidebar | explained only | Mac | yes |
| control.sidebar.folderSearch | Search sidebar folders | Sidebar > Folder search | explained only | Mac | no |
| control.sidebar.folderSearchClear | Clear the folder search | Sidebar > Folder search | explained only | Mac | no |
| control.sidebar.playlistButton | Choose the playlist | Sidebar > Playlist menu | explained only | Mac | no |
| control.sidebar.playlistRemove | Remove a playlist | Sidebar > Playlist menu | explained only | Mac | no |
| control.sidebar.playlistRow | A playlist in the menu | Sidebar > Playlist menu | explained only | Mac | no |
| control.statistics.area | Statistics area | Statistics | explained only | Mac | yes |
| control.statistics.weeklyDigest | Your week and the Sunday evening notification | Home > Statistics > Your week | sidebar statistics | Mac, iPhone, iPad | yes |
| control.title.folderPath | Open the folder a title is in | Title page | explained only | Mac, iPhone, iPad | yes |
| control.title.franchise | Films in the same franchise | Title page | explained only | Mac, iPhone, iPad | yes |
| control.title.otherLanguages | Other languages | Title page | explained only | Mac, iPhone, iPad | no |
| control.title.trailer | Watch the trailer | Title page | explained only | Mac, iPhone, iPad | yes |
| control.title.version | Choose a version | Title page | explained only | Mac, iPhone, iPad | yes |
| control.tonight.usualTime | Your usual time | Home > Tonight > Your usual time | sidebar tonight | Mac, iPhone, iPad | yes |
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
| setting.clickBehavior | Open channels with | Settings > General > Browsing | settings page General | Mac | yes |
| setting.collapseDuplicates | Group quality variants | Settings > General > Browsing | settings page General | Mac, iPhone, iPad | yes |
| setting.customTheme | Custom theme colours | Settings > Appearance > Theme | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.debrid | Debrid | Settings > Library > Debrid | settings page Library | Mac, iPhone, iPad | yes |
| setting.defaultAspect | Default aspect ratio | Settings > Playback > Video | settings page Playback | Mac | yes |
| setting.defaultChannelSort | Channel order | Settings > General > Browsing | settings page General | Mac, iPhone, iPad | yes |
| setting.defaultLibrarySort | Movies and series order | Settings > General > Browsing | settings page General | Mac, iPhone, iPad | yes |
| setting.defaultVideoSize | Default video size | Settings > Playback > Video | settings page Playback | Mac | yes |
| setting.deinterlace | Deinterlacing | Settings > Playback > Advanced video | settings page Playback | Mac | yes |
| setting.density | Density | Settings > Appearance > Appearance | settings page Appearance | Mac | yes |
| setting.downloads | Downloads | Settings > Library > Downloads | settings page Library | Mac, iPhone, iPad | yes |
| setting.downloadsDeleteWatched | Delete a download after I have watched it | Settings > Library > Downloads | settings page Library | Mac, iPhone, iPad | yes |
| setting.downloadsWifiOnly | Downloads only on Wi-Fi | Downloads > Only on Wi-Fi | explained only | iPhone, iPad | yes |
| setting.engineForKind | Player engine for live, movies or past programmes | Settings > Playback > Player engine | settings page Playback | Mac, iPhone, iPad | yes |
| setting.enginePreference | Player engine | Settings > Playback > Player engine | settings page Playback | Mac, iPhone, iPad | yes |
| setting.guide.addXMLTV | Add a guide address | Settings > Library > Guide sources > Add | explained only | Mac, iPhone, iPad | yes |
| setting.guide.enrichLogos | Fill missing logos | Settings > Library > Guide sources > Fill missing logos, genres and countries | explained only | Mac, iPhone, iPad | yes |
| setting.guide.enrichmentEnabled | Use the public channel database | Settings > Library > Guide sources | explained only | Mac, iPhone, iPad | yes |
| setting.guide.freshness | Guide warnings | Settings > Library > Guide sources | explained only | Mac, iPhone, iPad | yes |
| setting.guide.publicDatabase | Public channel database | Settings > Library > Guide sources > Fill missing logos, genres and countries | explained only | Mac, iPhone, iPad | yes |
| setting.guide.reminderLeadMinutes | Remind me before (guide reminders) | TV Guide > Reminders | explained only | Mac, iPhone, iPad | yes |
| setting.guide.sources | Guide sources | Settings > Library > Guide sources | explained only | Mac, iPhone, iPad | yes |
| setting.guide.timeZoneMode | Guide time zone | Settings > Library > Playlists | explained only | Mac, iPhone, iPad | yes |
| setting.guideHoursVisible | Guide hours shown | TV Guide screen > Hours visible | explained only | Mac | yes |
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
| setting.liveRewind | Pause and rewind live TV | Settings > Playback > Live TV | settings page Playback | Mac | yes |
| setting.maintenance | Maintenance and reset | Settings > Library > Maintenance | settings page Library | Mac, iPhone, iPad | yes |
| setting.music.adaptiveColours | Adapt colours to artwork | Music > Settings > General > Appearance | destination music | Mac | yes |
| setting.music.animatedArtwork | Animated artwork | Music > Settings > Playback > Animated artwork | destination music | Mac | yes |
| setting.music.audioCache | Audio cache | Music > Settings > Library & Data > Audio cache | destination music | Mac | yes |
| setting.music.audioQuality | Audio quality | Music > Settings > Playback > Audio | destination music | Mac | yes |
| setting.music.automix | Automix | Music > Settings > Playback > Automix | destination music | Mac | yes |
| setting.music.autoplay | Autoplay | Music > Settings > Playback > Player | destination music | Mac | yes |
| setting.music.backup | Export or import your music library | Music > Settings > Library & Data > Backup | destination music | Mac | yes |
| setting.music.catalogueInfo | Catalogue information | Music > Settings > Playback > Catalogue information | destination music | Mac | yes |
| setting.music.crossfade | Crossfade | Music > Settings > Playback > Player | destination music | Mac | yes |
| setting.music.deleteAllData | Delete all music data | Music > Settings > Privacy & About > Your data | destination music | Mac | yes |
| setting.music.devicesAllowControl | Allow other devices to control this one | Music > Settings > Devices > This device | destination music | Mac | yes |
| setting.music.equalizer | Equalizer | Music > Settings > Playback > Equalizer | destination music | Mac | yes |
| setting.music.globalHotkeys | Use global hotkeys | Music > Settings > Playback > Player > Global hotkeys | destination music | Mac | yes |
| setting.music.karaoke | Karaoke: remove vocals | Music > Settings > Playback > Karaoke | destination music | Mac | yes |
| setting.music.keepShuffleOn | Queue: keep shuffle on for new queues | Music > Settings > Playback > Queue | destination music | Mac | yes |
| setting.music.localFolders | Local folders | Music > Settings > Plugins & Sources > Local folders | destination music | Mac | yes |
| setting.music.lyricsBlur | Soft blur and glow on lyrics | Music > Settings > Lyrics > Lyrics display | destination music | Mac | yes |
| setting.music.lyricsOffset | Lyrics timing offset | Music > Settings > Lyrics > Lyrics display | destination music | Mac | yes |
| setting.music.lyricsSources | Lyrics sources | Music > Settings > Lyrics > Lyrics sources | destination music | Mac | yes |
| setting.music.menuBarItem | Menu bar item | Music > Settings > Playback > Player > Windows | destination music | Mac | yes |
| setting.music.normalizeVolume | Normalise volume | Music > Settings > Playback > Player | destination music | Mac | yes |
| setting.music.outputDevice | Output device (Play through) | Music > Settings > Playback > Output device | destination music | Mac | yes |
| setting.music.paxsenixKey | PaxSenix key | Music > Settings > Lyrics > Lyrics sources | destination music | Mac | yes |
| setting.music.playOnStart | Start playing when the app opens | Music > Settings > Playback > Player | destination music | Mac | yes |
| setting.music.pluginUpdates | Plugin updates | Music > Settings > Plugins & Sources > Plugin updates | destination music | Mac | yes |
| setting.music.preferWordByWord | Prefer word-by-word lyrics | Music > Settings > Lyrics > Lyrics display | destination music | Mac | yes |
| setting.music.queueMoveNotDuplicate | Queue: move instead of duplicating | Music > Settings > Playback > Queue | destination music | Mac | yes |
| setting.music.reduceMotion | Reduce motion (Music) | Music > Settings > General > Appearance | destination music | Mac | yes |
| setting.music.scrobbling | Scrobbling | Music > Settings > Plugins & Sources > Scrobbling | destination music | Mac | yes |
| setting.music.shuffleWholeQueue | Queue: shuffle the whole queue | Music > Settings > Playback > Queue | destination music | Mac | yes |
| setting.music.skipNonMusic | Skip non-music parts | Music > Settings > Playback > Audio | destination music | Mac | yes |
| setting.music.tagDownloads | Write song details into downloads | Music > Settings > Playback > Audio | destination music | Mac | yes |
| setting.music.textSize | Music text size | Music > Settings > General > Appearance | destination music | Mac | yes |
| setting.music.theatre | Theatre mode options | Music > Settings > Playback > Theatre mode | destination music | Mac | yes |
| setting.music.trackNotifications | Notify when the song changes | Music > Settings > Playback > Player > Windows | destination music | Mac | yes |
| setting.music.trackNotificationsFocused | Also notify when StreamSetu is open | Music > Settings > Playback > Player > Windows | destination music | Mac | yes |
| setting.music.translateLyricsInto | Translate lyrics into | Music > Settings > Lyrics > Lyrics display | destination music | Mac | yes |
| setting.music.videoMode | Show music videos | Music > Settings > Playback > Player look | destination music | Mac | yes |
| setting.music.wavySeekBar | Wavy seek bar | Music > Settings > Playback > Player look | destination music | Mac | yes |
| setting.music.windowTitle | Show the song in the window title | Music > Settings > Playback > Player > Windows | destination music | Mac | yes |
| setting.music.youtubeMusicAccount | the external service Music account | Music > Settings > Plugins & Sources > the external service Music | destination music | Mac | yes |
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
| setting.recordings | Recordings | Settings > Library > Recordings | settings page Library | Mac | yes |
| setting.reduceMotion | Reduce animation | Settings > Appearance > Appearance | settings page Appearance | Mac, iPhone, iPad | yes |
| setting.refreshOnOpen | Refresh when the app opens | Settings > Library > Catalog | settings page Library | Mac, iPhone, iPad | yes |
| setting.rememberFolders | Remember last folder | Settings > General > Browsing | settings page General | Mac, iPhone, iPad | yes |
| setting.rememberPerTitle | Remember settings for each title | Settings > Playback > Remembered choices | settings page Playback | Mac, iPhone, iPad | yes |
| setting.rememberPosition | Remember playback position | Settings > Playback > Behaviour | settings page Playback | Mac, iPhone, iPad | yes |
| setting.remindersEnabled | Programme reminders | Settings > General > Notifications | settings page General | Mac, iPhone, iPad | yes |
| setting.renderingProfile | Scaling quality | Settings > Playback > Advanced video | settings page Playback | Mac | yes |
| setting.resumeAutomatically | Resume automatically | Settings > Playback > Behaviour | settings page Playback | Mac, iPhone, iPad | yes |
| setting.resumeLastChannel | Resume the last channel | Settings > General > At launch | settings page General | Mac, iPhone, iPad | yes |
| setting.scheduledRecordings | Scheduled recordings | Settings > Library > Recordings | settings page Library | Mac | yes |
| setting.showDiagnosticsOverlay | Show stream information | Settings > Playback > Troubleshooting | settings page Playback | Mac, iPhone, iPad | yes |
| setting.sidebarLaunch | Sidebar at launch | Settings > Appearance > Appearance | settings page Appearance | Mac | yes |
| setting.stereoDownmix | Downmix to stereo | Settings > Playback > Advanced audio | settings page Playback | Mac | yes |
| setting.storage.guideBannerDismissed | Guide warning dismissed | TV Guide | explained only | Mac, iPhone, iPad | yes |
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
| setting.toneMapping | HDR tone mapping | Settings > Playback > Advanced video | settings page Playback | Mac | yes |
| setting.trakt | Trakt | Settings > Library > Trakt | settings page Library | Mac, iPhone, iPad | yes |
| setting.userAgent | User-Agent and headers for one playlist | Settings > Library > Manage > Playlists > Connection > Advanced connection | modal playlists | Mac, iPhone, iPad | yes |
| setting.videoQuality | Preferred quality | Settings > Playback > Video | settings page Playback | Mac, iPhone, iPad | yes |
| setting.viewingLimits | Viewing limits for a kids profile | Settings > Library > Profiles > Limits | settings page Library | Mac, iPhone, iPad | yes |
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
| menu.help.getSetUp | Get Set Up… | Menu bar > Help > Get Set Up… | window main | Mac | yes |
| menu.help.keyboardShortcuts | Keyboard Shortcuts | Menu bar > Help > Keyboard Shortcuts | window shortcuts | Mac | yes |
| menu.help.sendFeedback | Send Feedback… | Menu bar > Help > Send Feedback… | window feedback | Mac | yes |
| menu.navigate.home | Home | Menu bar > Navigate > Home | tab Home | Mac | yes |
| menu.navigate.liveTV | Live TV | Menu bar > Navigate > Live TV | tab Live TV | Mac | yes |
| menu.navigate.movies | Movies | Menu bar > Navigate > Movies | tab Movies | Mac | yes |
| menu.navigate.music | Music | Menu bar > Navigate > Music | destination music | Mac | yes |
| menu.navigate.podcasts | Podcasts | Menu bar > Navigate > Podcasts | destination podcasts | Mac | yes |
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
| menu.services.hideElement | Hide Element on This Page… | Menu bar > Services > Hide Element on This Page… | explained only | Mac | yes |
| menu.services.openInBrowser | Open in Default Browser | Menu bar > Services > Open in Default Browser | explained only | Mac | yes |
| menu.services.pin | Pin to Top Bar | Menu bar > Services > Pin to Top Bar | explained only | Mac | yes |
| menu.services.reload | Reload | Menu bar > Services > Reload | explained only | Mac | yes |
| menu.services.zoomIn | Zoom In | Menu bar > Services > Zoom In | explained only | Mac | yes |
| menu.services.zoomOut | Zoom Out | Menu bar > Services > Zoom Out | explained only | Mac | yes |
| menu.view.musicPalette | Music Command Palette | Menu bar > View > Music Command Palette | explained only | Mac | yes |
| menu.view.musicPanel | Show or Hide Details Panel | Menu bar > View > Show or Hide Details Panel | explained only | Mac | yes |
| menu.view.musicSidebar | Collapse or Expand Music Sidebar | Menu bar > View > Collapse or Expand Music Sidebar | explained only | Mac | yes |

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
| shortcut.music.forward | Forward and back between pages | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.globalHotkeys | Global hotkeys | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.like | Like or unlike the playing song | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.mute | Mute | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.nextPrev | Next and previous song | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.optionSpace | Option Space plays or pauses (works while typing) | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.playPause | Play or pause | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.queueUndo | Undo and redo in the queue | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.refresh | Refresh the page | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.roomLock | Keys in a listening room | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.search | Search keys in Music | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.seekKeys | Skip ten seconds | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.selectAll | Select all songs | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.shuffleRepeat | Shuffle and repeat keys | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.theatreKey | Theatre mode key | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.toggleNowPlaying | Open or close Now Playing | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.volumeKeys | Volume keys | Keyboard > Music | explained only | Mac | yes |
| shortcut.music.zoom | Zoom Music | Keyboard > Music | explained only | Mac | yes |
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
| shortcut.podcasts.keys | Podcasts keys | Keyboard > Podcasts | explained only | Mac | yes |
| shortcut.search.askSetu | Return in the search box asks Setu for a question | Keyboard > Search | search focus | Mac | yes |
| shortcut.search.down | Down arrow moves into the results | Keyboard > Search | explained only | Mac | yes |
| shortcut.search.escape | Esc clears the search | Keyboard > Search | explained only | Mac | yes |
| shortcut.search.forceAsk | Shift Return in the search box always asks Setu | Keyboard > Search | explained only | Mac | yes |
| shortcut.search.forceSearch | Option Return in the search box always searches | Keyboard > Search | explained only | Mac | yes |
| shortcut.search.results | Arrows and Return in search results | Keyboard > Search results | explained only | Mac | yes |
| shortcut.setu.send | Send a message to Setu | Keyboard > Setu | explained only | Mac | yes |
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
| context.podcasts.episode | Podcast episode menu | Podcasts > Show > Context menu | explained only | Mac | yes |
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
| intent.openSetting | Open a Setting (Siri and Shortcuts) | Siri and Shortcuts | explained only | iPhone, iPad | yes |
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
| guide.keyboard | Keyboard | Help > Keyboard | explained only | Mac, iPad | yes |
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
| recipe.music.addLanguage | Add a language to Music | Music > Explore > Languages | destination music | Mac | yes |
| recipe.music.blockSong | Never play a song or artist | Music > Never Play list | destination music | Mac | yes |
| recipe.music.changeCountry | Change the country for charts | Music > Explore | destination music | Mac | yes |
| recipe.music.connectLastFm | Connect Last.fm or ListenBrainz | Music > Settings > Plugins & Sources > Scrobbling | destination music | Mac | yes |
| recipe.music.downloadSongs | Download songs to play offline | Music > Downloads | destination music | Mac | yes |
| recipe.music.findFavouriteSongs | Find the songs I liked | Music > Your Library > Songs | destination music | Mac | yes |
| recipe.music.importPlaylist | Import a playlist | Music > Your Library | destination music | Mac | yes |
| recipe.music.pairDevice | Pair another device to control Music | Music > Devices | destination music | Mac | yes |
| recipe.music.setSleepTimer | Set a sleep timer for Music | Music > Player bar > Sleep timer | destination music | Mac | yes |
| recipe.music.signInYouTubeMusic | Sign in to the external service Music | Music > Settings > Plugins & Sources > the external service Music | destination music | Mac | yes |
| recipe.music.startListenTogether | Start a Listen Together room | Music > Listen Together | destination music | Mac | yes |
| recipe.music.turnOnCrossfade | Turn on crossfade | Music > Settings > Playback > Player | destination music | Mac | yes |
| recipe.music.useEqualizer | Use the equalizer | Music > Player bar > Equalizer | destination music | Mac | yes |
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
| diag.appLock | Locked out, or Touch ID fails | Settings > Privacy > App lock | settings page Privacy | Mac | yes |
| diag.artwork | Why posters are missing or wrong | Troubleshooting > Artwork | explained only | Mac, iPhone, iPad | yes |
| diag.backupRestore | A restored playlist is off or asks for a login | Settings > Library > Backup | settings page Library | Mac, iPhone, iPad | yes |
| diag.blackScreen | Why the picture is black or frozen | Troubleshooting > Picture | explained only | Mac, iPhone, iPad | yes |
| diag.castSearch | Why a search by actor finds nothing | Troubleshooting > Search | explained only | Mac, iPhone, iPad | yes |
| diag.channelsEmpty | Why a playlist shows no channels | Troubleshooting > Playlists | explained only | Mac, iPhone, iPad | yes |
| diag.continueEmpty | Why Continue Watching is empty | Troubleshooting > Continue Watching | explained only | Mac, iPhone, iPad | yes |
| diag.downloads | Why a download will not start or has paused | Troubleshooting > Downloads | explained only | Mac, iPhone, iPad | yes |
| diag.engine | Which player engine to use | Troubleshooting > Player engine | explained only | Mac, iPhone, iPad | yes |
| diag.guide | Why the TV guide is empty or the times are wrong | Troubleshooting > TV Guide | explained only | Mac, iPhone, iPad | yes |
| diag.hdrWashed | Why HDR video looks dull or washed out | Troubleshooting > Picture | explained only | Mac | yes |
| diag.libraryRebuilt | "Your library was rebuilt" and the Recovery folder | Settings > Advanced | settings page Advanced | Mac, iPhone, iPad | yes |
| diag.liveBehind | Why live TV is behind real time | Troubleshooting > Live TV | explained only | Mac, iPhone, iPad | yes |
| diag.lockedHidden | Why a folder or title has disappeared (locked folders) | Troubleshooting > Parental controls | explained only | Mac, iPhone, iPad | yes |
| diag.multiviewLimit | "Your provider's limit" alert in Multi-View | Multi-View | explained only | Mac | yes |
| diag.music.devicesNotFound | Devices cannot be found | Music > Devices | destination music | Mac | yes |
| diag.music.noChartsForCountry | No charts for my country | Music > Explore | destination music | Mac | yes |
| diag.music.noLyrics | No lyrics are showing | Music > Side panel > Lyrics | destination music | Mac | yes |
| diag.music.noSourceOn | No music source is switched on | Music > Listen Now | destination music | Mac | yes |
| diag.music.pairingLocked | Pairing is locked | Music > Devices | destination music | Mac | yes |
| diag.music.panelButtonMissing | The side panel button is missing | Music > Page top right | destination music | Mac | yes |
| diag.music.playerBarGone | The player bar is gone | Music > Player bar | destination music | Mac | yes |
| diag.music.sidebarNamesMissing | The sidebar shows only icons | Music > Sidebar | destination music | Mac | yes |
| diag.music.songWontPlay | A song will not play | Music > Player bar | destination music | Mac | yes |
| diag.noPipAirplay | Why Picture in Picture or AirPlay is not available | Troubleshooting > Player engine | explained only | Mac, iPhone, iPad | yes |
| diag.noSound | Why there is no sound | Troubleshooting > Sound | explained only | Mac, iPhone, iPad | yes |
| diag.playback | Why a stream will not play or keeps buffering | Troubleshooting > Playback | explained only | Mac, iPhone, iPad | yes |
| diag.profileFavourites | Why favourites or history are missing | Troubleshooting > Profiles | explained only | Mac, iPhone, iPad | yes |
| diag.proxyDns | Nothing loads after proxy, App DNS or VPN | Settings > Privacy | settings page Privacy | Mac, iPhone, iPad | yes |
| diag.recording | Why a recording fails or did not happen | Troubleshooting > Recordings | explained only | Mac | yes |
| diag.reminders | Why programme reminders do not appear | Troubleshooting > Reminders | explained only | Mac, iPhone, iPad | yes |
| diag.searchEmpty | Why search finds nothing | Troubleshooting > Search | explained only | Mac, iPhone, iPad | yes |
| diag.source | Why a playlist will not load or its login is rejected | Troubleshooting > Playlists | explained only | Mac, iPhone, iPad | yes |
| diag.streamingService | A streaming service page will not open | Services | explained only | Mac | yes |
| diag.subtitlesMissing | Why subtitles do not show | Troubleshooting > Subtitles | explained only | Mac, iPhone, iPad | yes |
| diag.subtitlesOutOfSync | Why subtitles or sound are out of sync | Troubleshooting > Subtitles | explained only | Mac, iPhone, iPad | yes |
| diag.sync | Why sync between devices is not working | Troubleshooting > Sync | explained only | Mac, iPhone, iPad | yes |
| diag.viewingBlock | "That's enough for today" or "It's time to rest" | Settings > Library > Profiles | settings page Library | Mac, iPhone, iPad | yes |
| diag.vpnPause | Why playback stops when a VPN drops | Troubleshooting > VPN | explained only | Mac, iPhone, iPad | yes |

## About Setu and what is new

| Id | Title | Where | Opens | Platforms | Reviewed |
|---|---|---|---|---|---|
| behaviour.music.countryRules | How the country choice works | Music > Explore > Country | destination music | Mac | yes |
| behaviour.music.notifications | Song-change notifications | Music > Settings > Playback | destination music | Mac | yes |
| meta.canDoHere | What can I do here? | Setu | explained only | Mac, iPhone, iPad | yes |
| meta.compareToOthers | StreamSetu compared with other apps | About | modal about | Mac, iPhone, iPad | yes |
| meta.deepLinks | streamsetu:// links | Help > Links | explained only | Mac, iPhone, iPad | yes |
| meta.differencesByPlatform | What is not on every app | About | modal about | Mac, iPhone, iPad | yes |
| meta.pricing | Price and licence | About > Licenses | modal about | Mac, iPhone, iPad | yes |
| meta.privacySetu | What Setu sends and keeps | Setu > Privacy | explained only | Mac, iPhone, iPad | yes |
| meta.setuCanChange | What Setu can change, and what it never changes | Setu > What I can do | explained only | Mac, iPhone, iPad | yes |
| meta.setuTools | What Setu can look up | Setu > What I can do | explained only | Mac, iPhone, iPad | yes |
| meta.smartMix | Smart Mix: how Home picks titles | Home > Discover | sidebar discover | Mac, iPhone, iPad | yes |
| meta.supportedDevices | Which devices and system versions | About | modal about | Mac, iPhone, iPad | yes |
| meta.supportedFormats | What streams and files play | Settings > Playback > Player engine | settings page Playback | Mac, iPhone, iPad | yes |
| meta.whatIsStreamSetu | What StreamSetu is and is not | About | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew | What's new | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.2026.11.02 | New on Fire TV and Android in November | About > What's new | explained only | none | yes |
| meta.whatsNew.2026.11.07 | New in Mac 2.16.0 | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.2026.11.21 | New in Mac 2.17.0 and iPhone 1.3 | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.2026.11.23 | New in Mac 2.18.0 and iPhone and iPad 1.4 | About > What's new | modal about | Mac, iPhone, iPad | yes |
| meta.whatsNew.2026.11.23.ios | New in iPhone and iPad 1.4: the Setu assistant | About > What's new | modal about | iPhone, iPad | yes |
| meta.whatsNew.2026.11.23.mac | New in Mac 2.18.0: streaming services inside the app | About > What's new | modal about | Mac | yes |
| meta.whatsNew.music | New in the Mac app: Music | About > What's new | destination music | Mac | yes |
| meta.widgetsAndActivity | Widgets and Live Activity | Help > Widgets | explained only | iPhone, iPad | yes |

---

# What Setu can do for you (actions)

Generated from the code by the coverage tests. **Reported, pending independent verification.** Verification means automated tests on macOS only: iPhone/iPad code compiles but is not run, and Android and Fire TV have none of this.

Columns: *UI* = the app has its own control · *Read* = how the assistant looks at it · *Act* = what it can offer (always tap-to-confirm, rechecked by the authorizer) · *Restrictions tested* · *Error path tested* · *Platforms verified*.

**210 rows: 154 covered, 56 unsupported with a reason.**


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
| music.control | same service: MusicPlayer / MusicLibrary (the same calls the player bar uses) | — | control, scope session, inputs: action: play|pause|next|previous|shuffle_on|shuffle_off|repeat_off|repeat_all|repeat_one|like|unlike|volume_up|volume_down|mute|unmute|show_lyrics|show_queue, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | macOS |
| music.country | same service: MusicRegionChoice (the same choice the country picker sets) | — | preference, scope profile, inputs: country: ISO code or worldwide, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | macOS |
| music.open | same service: MusicHub.nav | — | control, scope session, inputs: screen: listen_now|explore|search|library|radio|downloads|devices|listen_together|settings, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | macOS |
| music.play | same service: MusicHub.play / playShuffled (the same calls the play buttons use) | — | control, scope session, inputs: query: text, kind: song|artist|album|playlist|any, shuffle: bool, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | macOS |
| music.radio | same service: MusicQueueActions.startRadio | — | control, scope session, inputs: from: song or artist name, or what is playing, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | macOS |
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
| music_control | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| music_country | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| music_now_playing | n/a | read | — | n/a (read only) | yes | macOS · iOS compiled, not run |
| music_open | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| music_play | n/a | — | offers; authorizer rechecks | yes: tested | yes | macOS · iOS compiled, not run |
| music_search | n/a | read (sends only the words to the Music source the person turned on) | — | n/a (read only) | yes | macOS · iOS compiled, not run |
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
| DesignSystem/Components/Sidebar/ReddySidebar.swift | yes | — | — | — | — | **Unsupported:** Sidebar folder menu (Move, Hide, Lock, Unlock): explained as context.sidebar.folderReorder and context.sidebar.folderLock; playlist menu row (Remove…): explained as screen.playlistMenu. Not run by Setu. |
| Features/CommandCenter/Views/CommandCenterView.swift | yes | — | — | — | — | **Unsupported:** Channel and folder manager menus: not mapped yet. |
| Features/Files/FilesView.swift | yes | — | — | — | — | **Unsupported:** Local file menu: not mapped yet. |
| Features/Files/PodcastsView.swift | yes | — | — | — | — | **Unsupported:** Podcast menu: not mapped yet. |
| Features/Home/Views/HomeScreen.swift | yes | — | — | — | — | **Unsupported:** Title card menu (favourite, watch later, hide): reachable as the favourite and watch_later tools, not as its own entry. |
| Features/LiveTV/Views/LiveTVScreen.swift | yes | — | — | — | — | **Unsupported:** Channel menu (favourite, reminders, versions): partly reachable as favourite and play_title. |
| Features/Music/Autoplay/MusicShuffleAutoplayViews.swift | yes | — | — | — | — | **Unsupported:** Shuffle style menu (Smart, True random, Smart Shuffle, Reshuffle, Autoplay): explained as control.music.shuffleMode and its neighbours, not run by Setu. |
| Features/Music/Graph/Album/MusicSoundtrackSongsSection.swift | yes | — | — | — | — | **Unsupported:** Album song row menu (play, the song menu, song details): explained as control.music.soundtrackSongRow, not run by Setu. |
| Features/Music/Home/MusicHomeContinue.swift | yes | — | — | — | — | **Unsupported:** Listen Now Continue listening tile: the song menu, explained as control.music.homeContinueCard. |
| Features/Music/Home/MusicHomeRows.swift | yes | — | — | — | — | **Unsupported:** Listen Now top-tracks row: the song menu, explained as control.music.homeTopTrackRow. |
| Features/Music/Home/MusicHomeTile.swift | yes | — | — | — | — | **Unsupported:** Listen Now mix tile menu (Play, Shuffle, Play next, Add to queue): explained as control.music.homeTile, not run by Setu. |
| Features/Music/MusicCards.swift | yes | — | — | — | — | **Unsupported:** Music card menus (play, play next, add to queue, radio, add to playlist, share): explained as control.music.* entries, not run by Setu. |
| Features/Music/MusicComponents.swift | yes | — | — | — | — | **Unsupported:** Music card and song row menus (play, play next, add to queue, radio, add to playlist, share): explained as control.music.* entries, not run by Setu. |
| Features/Music/MusicLibraryContent.swift | yes | — | — | — | — | **Unsupported:** Library grid card and row menus (the same card menu): explained as control.music.* entries, not run by Setu. |
| Features/Music/MusicLibraryRows.swift | yes | — | — | — | — | **Unsupported:** Library song row menu (the same song menu): explained as control.music.* entries, not run by Setu. |
| Features/Music/MusicNowPlayingPanel.swift | yes | — | — | — | — | **Unsupported:** Now Playing artwork menu (view album, view artwork): explained as control.music.* entries, not run by Setu. |
| Features/Music/MusicPlayerBar.swift | yes | — | — | — | — | **Unsupported:** Player bar menus (the shuffle button's menu and the more menu): explained as control.music.* entries, not run by Setu. |
| Features/Music/MusicPlayerViews.swift | yes | — | — | — | — | **Unsupported:** Queue and now-playing row menu (Go to album, artist, film): explained as control.music.* entries, not run by Setu. |
| Features/Music/MusicRadioStationCards.swift | yes | — | — | — | — | **Unsupported:** Radio station card menu (Start, Edit, Make a copy, Delete): explained under the Radio station controls, not run by Setu. |
| Features/Music/MusicSearchPage.swift | yes | — | — | — | — | **Unsupported:** Music search result menu (the same card menu): explained as control.music.* entries, not run by Setu. |
| Features/Music/MusicSearchSuggest.swift | yes | — | — | — | — | **Unsupported:** Music search suggestion menu (play and the song menu): explained as control.music.* entries, not run by Setu. |
| Features/Music/MusicSidebar.swift | yes | — | — | — | — | **Unsupported:** Sidebar playlist menu (Play, Shuffle, Rename, Delete): explained as the playlist page's own controls (control.music.albumArtistAndPlaylistPages*), not run by Setu. |
| Features/Music/Playlist/MusicSmartPlaylistScreens.swift | yes | — | — | — | — | **Unsupported:** Smart playlist chip menu in the Playlists tab (Edit, Duplicate, Delete): explained as control.music.smartEdit, control.music.smartDuplicate and control.music.smartDelete, not run by Setu. |
| Features/Music/Settings/MusicSettingsComponents.swift | yes | — | — | — | — | **Unsupported:** Music settings row menu: explained as control.music.* entries, not run by Setu. |
| Features/Music/Setup/MusicSetupSheet.swift | yes | — | — | — | — | **Unsupported:** Genre chip menu (Like, Love, Not for me) in setup: explained as control.music.setupGenre*, not run by Setu. |
| Features/Player/Views/MultiViewWindow.swift | yes | — | — | — | — | **Unsupported:** Multi-view tile menu: not mapped yet. |
| Features/Podcasts/PodcastShowPage.swift | yes | — | — | — | — | **Unsupported:** Podcast episode menu (Play Next, Add to Up Next, Mark as Played): context.podcasts.episode. |
| Features/Podcasts/PodcastsMainView.swift | yes | — | — | — | — | **Unsupported:** Podcast menu in the main window (Unfollow): context.podcasts.show. |
| Features/Series/Views/EpisodeCard.swift | yes | — | — | — | — | **Unsupported:** Episode menu (play, watch privately, mark watched, reset progress): declared in the Atlas as the episode menu; not an assistant action yet. |
| Features/Shared/TileMenu.swift | yes | — | — | — | — | **Unsupported:** Title menu on every tile (one shared builder): partly reachable as favourite, watch_later and play_title. |
| Features/Sources/Views/PlaylistManager.swift | yes | — | — | — | — | **Unsupported:** Playlist row menu (Remove…, with the same confirmation as the Remove button): not mapped yet. |
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
| Music | yes | — | — | — | — | **Unsupported:** The Music section of the main window: Setu points to its screens and settings and explains each control (control.music.*), but does not search, queue or play songs for you. |
| the external service | yes | — | — | — | — | **Unsupported:** One of the outside websites (streaming services) shown in a web view (Mac only), with the Services menu and pinned items in the top bar. Setu does not read or control any of them: nothing is injected into the page, and sign-in, cookies and playback stay between the person and the website. |
| Onboarding | yes | — | — | — | — | **Unsupported:** First-run screens; the assistant is not shown there. |
| Opening | yes | — | — | — | — | **Unsupported:** The opening and What's New at launch; the assistant is not shown there. |
| Player | yes | diagnose_playback, now_playing, recommend_engine | control_playback, retry_playback, switch_engine, select_track | yes: AssistantAuthorizer (session, profile) | yes: diagnosis table | macOS · iOS compiled, not run |
| Podcasts | yes | — | — | — | — | **Unsupported:** Podcasts in the main window (top row or Services list, ⌘7): Setu points to it (screen.destination.podcasts) but does not search, follow or play shows. |
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
| addedThisMonth | yes | screen name | open_screen(addedThisMonth) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| allChannels | yes | screen name | open_screen(liveTV) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| allMovies | yes | screen name | open_screen(movies) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| collections | yes | screen name | open_screen(collections) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| continueWatching | yes | screen name | open_screen(continueWatching), resume_watching | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| discover | yes | screen name | open_screen(discover) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| favorites | yes | screen name | open_screen(favorites), favourite | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| featured | yes | screen name | open_screen(featured) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| library | yes | screen name | open_screen(series) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| newEpisodes | yes | screen name | open_screen(newEpisodes) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| recentlyAdded | yes | screen name | open_screen(recentlyAdded) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| recentlyWatched | yes | screen name | open_screen(recentlyWatched) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| statistics | yes | screen name; totals via watch_stats | open_screen(statistics) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| tonight | yes | screen name | open_screen(tonight) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| unwatched | yes | screen name | open_screen(unwatched) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| unwatchedFavorites | yes | screen name | open_screen(unwatchedFavorites) | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
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
