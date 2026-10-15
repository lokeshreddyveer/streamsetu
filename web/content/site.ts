export const site = {
  name: "StreamSetu",
  tagline: "Your streams. One home.",
  description: "StreamSetu plays the IPTV playlists and media servers you already have, on Mac, iPhone, iPad, Android, Fire TV and Android TV. No account, no ads, no tracking.",
  repo: "https://github.com/lokeshreddyveer/streamsetu",
  testflight: "https://testflight.apple.com/join/wYZ3vysQ",
  email: "contact@lokeshreddy.dev",
};

export const platforms = [
  { id: "mac", name: "Mac", detail: "Apple silicon and Intel, macOS 14 or later" },
  { id: "ios", name: "iPhone and iPad", detail: "iOS 18 or later, through TestFlight for now" },
  { id: "android", name: "Android phone and tablet", detail: "Android 5.1 or later" },
  { id: "tv", name: "Fire TV and Android TV", detail: "Made for the remote, Android 5.1 or later" },
  { id: "windows", name: "Windows", detail: "Coming soon" },
];

export const highlights = [
  { title: "Everything in one library", text: "Add as many playlists and servers as you like and see them as one library. A film that sits in two of them is one film to you." },
  { title: "Find it in a second", text: "Search runs on your own device, so it is quick and works offline. Type \"hindi movies 2024\" and it understands." },
  { title: "Nothing leaves your device", text: "No account to make, nothing to sign in to, no ads and no tracking. Your library, logins and history stay on your device. The few optional extras that contact someone else, such as iCloud sync, TMDB artwork or subtitles, are off until you turn them on, and the privacy policy lists each one." },
];

export const features = [
  { title: "Live TV and the guide", text: "Channels in groups with their numbers, a full TV guide, catch-up for programmes that already aired, reminders for the ones that have not, and radio mode." },
  { title: "Movies and series", text: "Resume where you stopped, a row for what to watch next, new episodes marked on the series, and More Like This under every title, with the reason it was suggested." },
  { title: "Search that understands you", text: "One search over channels, movies, series, episodes and the guide. It fixes a misspelt word and works without a connection. It is also inside the player." },
  { title: "A player with depth", text: "Audio and subtitle choices, speed, picture size, timing, a sleep timer, go to an exact time, Skip Intro, picture tuning, volume boost and a stats overlay for those who like the numbers." },
  { title: "Remembers your choices", text: "Audio language, subtitles, speed and timing come back the next time you play the same title or channel." },
  { title: "Subtitles from OpenSubtitles", text: "Use your own free key to search and download subtitles without leaving the player." },
  { title: "Multi-View", text: "Watch up to four live channels side by side, with the sound on one at a time." },
  { title: "Folders, favourites and lists", text: "Sort the provider's folders your way, lock one with a PIN, keep favourites, Watch Later and collections, and clear any of them in one go." },
  { title: "Hindi and Telugu", text: "The main screens are available in Hindi and Telugu as well as English." },
];

export const sources = [
  "Xtream Codes logins",
  "M3U playlists, as a link or a file",
  "Stalker and Ministra portals",
  "Jellyfin, Emby and Plex",
  "HDHomeRun, TVHeadend and Enigma2",
  "WebDAV shares and folders of videos",
];

export const faq = [
  {
    q: "Does StreamSetu come with channels or films?",
    a: "No. StreamSetu is a player only. It provides no channels, movies, series or subscriptions, and it does not ship or link to any content. You bring your own legally obtained playlist or login.",
  },
  {
    q: "Do I need an account?",
    a: "No. There is nothing to sign up for. Your playlists, favourites and history stay on your device.",
  },
  {
    q: "What does it cost?",
    a: "The downloads on this site are free.",
  },
  {
    q: "Which playlists work?",
    a: "Xtream Codes, M3U links and files, Stalker portals, Jellyfin, Emby, Plex, HDHomeRun, TVHeadend, Enigma2 and WebDAV. If your provider gave you a username, a password and an address, or a link ending in .m3u, it will work.",
  },
  {
    q: "How do I get it on an iPhone?",
    a: "Through TestFlight. Open the invitation link on the Download page on your iPhone, install TestFlight if asked, and tap Install.",
  },
  {
    q: "How do I install it on a Fire TV?",
    a: "Turn on Install unknown apps for the Downloader app in Settings, My Fire TV, Developer options. Open Downloader, enter the address of the Fire TV file from the Download page, and install.",
  },
  {
    q: "Does the Mac app update itself?",
    a: "Yes. The Android and Fire TV apps check for updates too and ask before installing.",
  },
  {
    q: "Is there a Windows version?",
    a: "Not yet. It is coming.",
  },
];
