# Assistant coverage matrix

Generated from the code by the coverage tests. **Reported, pending independent verification.** Verification means automated tests on macOS only: iPhone/iPad code compiles but is not run, and Android and Fire TV have none of this.

Columns: *UI* = the app has its own control · *Read* = how the assistant looks at it · *Act* = what it can offer (always tap-to-confirm, rechecked by the authorizer) · *Restrictions tested* · *Error path tested* · *Platforms verified*.

**166 rows: 135 covered, 31 unsupported with a reason.**


## agent action

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
| player.control | same service: PlaybackCoordinator | — | control, scope session, inputs: action: pause|play|mute|unmute|volume_up|volume_down|forward|back|next_episode|stop, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| player.engine | same service: PlaybackCoordinator.switchEngine / AppSettings.enginePreference | — | control, scope session, inputs: engine: mpv|avPlayer|auto, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| player.retry | same service: PlaybackCoordinator.retryNow | — | control, scope session, inputs: none, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| player.track | same service: PlaybackCoordinator.selectAudio / selectSubtitle | — | control, scope session, inputs: kind: audio|subtitle, track: available track, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| playlists.refresh | same service: AppState.syncAll | — | control, scope device, inputs: none, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |
| settings.change | same service: AppSettings (same properties the Settings screens bind to) | — | preference, scope profile, inputs: id: catalogue setting, value: allowed option, no confirmation | yes: AssistantAuthorizer tests | yes: stale, profile, locked folder | iOS, macOS |

## agent tool

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

## context menu

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| DesignSystem/Components/Sidebar/ReddySidebar.swift | yes | — | — | — | — | **Unsupported:** Sidebar folder menu (lock, hide, rename): not mapped yet. |
| Features/CommandCenter/Views/CommandCenterView.swift | yes | — | — | — | — | **Unsupported:** Channel and folder manager menus: not mapped yet. |
| Features/Files/FilesView.swift | yes | — | — | — | — | **Unsupported:** Local file menu: not mapped yet. |
| Features/Files/PodcastsView.swift | yes | — | — | — | — | **Unsupported:** Podcast menu: not mapped yet. |
| Features/Home/Views/HomeScreen.swift | yes | — | — | — | — | **Unsupported:** Title card menu (favourite, watch later, hide): reachable as the favourite and watch_later tools, not as its own entry. |
| Features/LiveTV/Views/LiveTVScreen.swift | yes | — | — | — | — | **Unsupported:** Channel menu (favourite, reminders, versions): partly reachable as favourite and play_title. |
| Features/Movies/Views/LibraryScreen.swift | yes | — | — | — | — | **Unsupported:** Title menu: partly reachable as favourite, watch_later and play_title. |
| Features/Player/Views/MultiViewWindow.swift | yes | — | — | — | — | **Unsupported:** Multi-view tile menu: not mapped yet. |
| Features/Series/Views/SeriesDetailView.swift | yes | — | — | — | — | **Unsupported:** Episode menu (mark watched): not mapped yet. |
| Features/TVGuide/Components/GuideRow.swift | yes | — | — | — | — | **Unsupported:** Programme menu (remind, record): not mapped yet. |

## feature

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
| Onboarding | yes | — | — | — | — | **Unsupported:** First-run screens; the assistant is not shown there. |
| Player | yes | diagnose_playback, now_playing, recommend_engine | control_playback, retry_playback, switch_engine, select_track | yes: AssistantAuthorizer (session, profile) | yes: diagnosis table | macOS · iOS compiled, not run |
| RecentlyWatched | yes | — | — | — | — | **Unsupported:** History is summarised by watch_stats but not searchable or editable by the assistant yet. |
| Search | yes | search_everything (same engine as the search box) | open_screen with filter words | n/a | yes | macOS · iOS compiled, not run |
| Series | yes | search_everything, title_details, similar_titles | play_title, favourite, watch_later | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| Settings | yes | find_setting, find_help | change_setting (catalogued settings only) | yes: AssistantAuthorizer | yes: invalid and unchangeable settings | macOS · iOS compiled, not run |
| Shared | n/a | — | — | — | — | **Unsupported:** Shared building blocks, not a feature. |
| Sources | yes | source_health, guide_status, source_setup_help | refresh_playlists (offered) | yes: AssistantAuthorizer; credentials never read | yes | macOS · iOS compiled, not run |
| TVGuide | yes | tv_guide, guide_status | sync_guide (offered) | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |

## modal

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| about | yes | — | — | — | — | **Unsupported:** Nothing for the assistant to read or do. |
| addPlaylist | yes | how-to via source_setup_help; never reads or stores credentials | explains the fields only | n/a (credentials go through the normal form into the Keychain) | no | macOS · iOS compiled, not run |
| channelManager | yes | — | — | — | — | **Unsupported:** Channel and folder management is not mapped to the registry yet (planned: read-only inspection first, then previewed changes). |
| playlists | yes | sanitized status via source_health | refresh_playlists (offered), open_screen(settings) | yes: AssistantAuthorizer (profile, freshness) | yes: source_health failures | macOS · iOS compiled, not run |
| unlockRestricted | yes | — | — | — | — | **Unsupported:** By design: PINs are entered only in the normal secure form; the assistant never unlocks anything. |

## setting

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| accent | yes | find_setting (value, options, where) | change_setting | yes: AssistantAuthorizer + value check | yes: invalid value, unchangeable | macOS · iOS compiled, not run |
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

## settings tab

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| advanced | yes | find_setting covers: Advanced (explain only: diagnostics, reset) | none by design | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| appearance | yes | find_setting covers: Appearance | change_setting for catalogued settings | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| general | yes | find_setting covers: General | change_setting for catalogued settings | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| library | yes | find_setting covers: Library | change_setting for catalogued settings | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| playback | yes | find_setting covers: Playback | change_setting for catalogued settings | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |
| privacy | yes | find_setting covers: Privacy (explain only: lock, proxy, VPN, parental) | none by design | yes: AssistantAuthorizer | yes | macOS · iOS compiled, not run |

## sidebar shortcut

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

## tab

| Feature | UI wired | Agent read | Agent action | Restrictions tested | Error path tested | Platforms verified |
|---|---|---|---|---|---|---|
| guide | yes | screen name; programmes via tv_guide, guide_status | open_screen, sync_guide | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| home | yes | screen name in context | open_screen | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| liveTV | yes | screen name in context; channels via search_everything, tv_guide | open_screen, play_title | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| movies | yes | screen name; titles via search_library, title_details | open_screen with filter words, play_title | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
| series | yes | screen name; titles via search_everything, title_details, similar_titles | open_screen with filter words, play_title | yes: AssistantAuthorizer | n/a | macOS · iOS compiled, not run |
