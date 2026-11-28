import Foundation

/// Spoken forms of the most common asks in Hinglish and in Telugu written in Latin letters ("subtitles kaise on kare", "queue ela clear cheyali"), added as aliases to the entries that answer them.
/// The question words themselves (kaise, kahan, kyun, ela, ekkada, enduku, cheyali and so on) are read by IntentDetector and ignored by retrieval, so the aliases mostly carry the topic words and
/// the two languages' own words for them. A test checks every id here is a real entry.
extension AtlasTuning {
    static let indic: [String: [String]] = [
        "recipe.setupSubtitles": ["subtitles kaise on kare", "subtitle ela on cheyali", "subtitles kaise lagaye", "subtitle ela pettali", "subtitles dikhao", "subtitles kaise dekhe"],
        "setting.subtitlesByDefault": ["subtitles hamesha on kaise kare", "subtitles ela always on cheyali"],
        "setting.subtitleSize": ["subtitle bada kaise kare", "subtitle size ela penchali", "subtitle chota bada"],
        "control.music.playerAndQueueLyrics": ["lyrics kaise dekhe", "lyrics ela chudali", "lyrics kahan dikhte hai", "gaane ke lyrics kahan", "paata lyrics ekkada", "song lyrics kaise on kare"],
        "control.music.playerAndQueueClearQueue": ["queue clear kaise", "queue ela clear cheyali", "queue khali kaise kare", "queue saaf karo", "queue ni clear ela"],
        "control.music.playerAndQueueQueue": ["queue kahan hai", "queue ekkada undi", "next songs kahan dikhte hai", "up next kaise dekhe"],
        "screen.music.search": ["song play ela", "song kaise play kare", "gaana kaise chalaye", "song ela search cheyali", "gaana kahan milega", "paata ela play cheyali", "song ekkada dorukutundi"],
        "recipe.sleepTimer": ["sleep timer kaise lagaye", "sleep timer ela pettali", "timer lagao band hone ke liye"],
        "control.music.sleepTimerMusic": ["music sleep timer kaise lagaye", "music sleep timer ela pettali", "gaane band hone ka timer"],
        "recipe.fixBuffering": ["buffering kyun ho raha hai", "video atak raha hai", "buffering enduku vastundi", "stream hang ho raha hai", "video aagi aagi vastundi"],
        "diag.noSound": ["sound nahi aa raha", "awaaz nahi aa rahi", "sound ledu", "audio ledu enduku", "awaaz kyun nahi aa rahi"],
        "recipe.fixEmptyGuide": ["guide khali kyun hai", "guide enduku empty ga undi", "guide mein kuch nahi dikh raha", "epg nahi aa raha"],
        "recipe.download": ["download kaise kare", "movie download ela cheyali", "offline kaise dekhe", "internet ke bina kaise dekhe"],
        "recipe.favoritesWatchLater": ["favourite kaise add kare", "favourite ela add cheyali", "baad mein dekhne ke liye kaise save kare", "watch later ela pettali"],
        "recipe.changeTheme": ["theme kaise badle", "dark mode ela on cheyali", "dark mode kaise lagaye", "rang kaise badle"],
        "recipe.kidsProfile": ["bachon ke liye profile kaise banaye", "pillala profile ela cheyali", "kids profile kaise banaye"],
        "setting.volume": ["awaaz kaise badhaye", "volume ela penchali", "volume kaise kam kare", "awaaz kam kaise kare"],
        "recipe.refreshPlaylist": ["playlist refresh kaise kare", "playlist update ela cheyali", "playlist naya kaise kare"],
        "recipe.record": ["recording kaise kare", "record ela cheyali", "channel record kaise kare"],
        "recipe.backupRestore": ["backup kaise le", "backup ela teesukovali", "restore kaise kare", "backup se wapas kaise laye"],
        "menu.file.addPlaylist": ["playlist add kaise kare", "playlist ela add cheyali", "naya playlist kaise jode"],
        "recipe.music.turnOnCrossfade": ["crossfade kaise on kare", "crossfade ela on cheyali"],
        "recipe.music.useEqualizer": ["equalizer kahan hai", "equalizer ekkada undi", "bass kaise badhaye", "bass ela penchali"],
        "recipe.music.changeCountry": ["country kaise badle music mein", "desham ela marchali", "chart ka desh kaise badle"],
        "recipe.music.signInYouTubeMusic": ["youtube music mein login kaise kare", "youtube music login ela cheyali", "youtube music sign in kaise kare"],
        "recipe.music.connectLastFm": ["lastfm kaise jode", "lastfm ela connect cheyali", "scrobbling kaise on kare"],
        "recipe.music.downloadSongs": ["gaane download kaise kare", "paatalu download ela cheyali", "songs offline kaise save kare"],
        "recipe.music.startListenTogether": ["saath mein gaane kaise sune", "friends tho kalisi paatalu ela vinali", "listen together kaise shuru kare"],
        "recipe.music.pairDevice": ["phone se music kaise control kare", "phone nundi music ela control cheyali"],
        "diag.music.devicesNotFound": ["devices nahi mil rahe", "devices kanipinchatledu", "phone nahi dikh raha"],
        "recipe.music.findFavouriteSongs": ["pasand ke gaane kahan hai", "favorite songs ekkada", "liked songs kahan dikhte hai"],
        "recipe.music.blockSong": ["song kabhi mat bajao", "ee song ni ekkadaa play cheyyakandi"],
        "recipe.music.addLanguage": ["bhasha kaise add kare music mein", "language ela add cheyali music lo"],
        "diag.music.noLyrics": ["lyrics nahi dikh rahe", "lyrics kyun nahi aa rahe", "lyrics ledu enduku"],
    ]
}
