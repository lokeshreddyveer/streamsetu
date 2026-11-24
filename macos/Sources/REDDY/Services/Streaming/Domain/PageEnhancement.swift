import Foundation

/// An optional, user-enabled addition to how a service's page behaves. Configuration only: a service lists the ones it supports in its
/// definition, and nothing runs unless the person turned it on and agreed to what it does. Every enhancement is off until then.
enum PageEnhancement: String, CaseIterable, Sendable, Identifiable {
    /// Removes the ad schedule from the page's player data, hides ad elements and skips an ad that still starts.
    case adSkip
    /// Skips the stretches of a video that people have marked as sponsor segments (asks a third-party service, by a short hash prefix).
    case sponsorSkip
    /// Spotify only. Hides ad and upgrade-prompt elements of the web player and stops the page asking the service's ad endpoints (a system-compiled
    /// content rule list on that one web view; no script).
    case spotifyHideAds
    /// Spotify only. Mutes the page's audio output only while the player shows that an ad is playing, and puts it back when the ad ends (a small script).
    case spotifyMuteAds

    var id: String { rawValue }
    var isSpotifyOption: Bool { self == .spotifyHideAds || self == .spotifyMuteAds }

    /// Bumped when what an enhancement does or sends changes, so an earlier agreement no longer counts.
    var consentVersion: Int { 1 }
    var enabledKey: String { "enhancement.\(rawValue).enabled" }
    var consentKey: String { "enhancement.\(rawValue).consent" }

    /// Plain English text of the setting; looked up in the language tables.
    var title: String {
        switch self {
        case .adSkip: "Skip ads"
        case .sponsorSkip: "Skip sponsor segments"
        case .spotifyHideAds: "Hide ads and upgrade prompts"
        case .spotifyMuteAds: "Mute audio ads"
        }
    }
    var summary: String {
        switch self {
        case .adSkip: "Removes video ads from the page where it can. Off by default."
        case .sponsorSkip: "Jumps over parts of a video that people have marked as sponsor reads. Off by default."
        case .spotifyHideAds: "Hides ad boxes and upgrade prompts on the Spotify page where it can. Off by default."
        case .spotifyMuteAds: "Mutes Spotify while an audio ad plays, then restores the sound. Off by default."
        }
    }
    /// The explanation shown before turning it on: what it does, what is sent, and the risks.
    var consentTitle: String {
        switch self {
        case .adSkip: "Turn on ad skipping?"
        case .sponsorSkip: "Turn on sponsor skipping?"
        case .spotifyHideAds: "Hide Spotify ads and upgrade prompts?"
        case .spotifyMuteAds: "Mute Spotify audio ads?"
        }
    }
    var consentMessage: String {
        switch self {
        case .adSkip: "StreamSetu will run a small script inside the YouTube page to remove the ad schedule from the player's data, hide ad boxes and skip an ad that still starts. Nothing is sent anywhere. Risks: YouTube changes often, so this can stop working or make a page misbehave; it may go against YouTube's terms; and ads are how creators and YouTube are paid. Turn it off any time in Settings, then reload the page."
        case .sponsorSkip: "While you watch a YouTube video, StreamSetu asks sponsor.ajay.app (the SponsorBlock project's server) which parts people marked as sponsor reads, and skips them with an Undo button. It sends only the first 4 characters of a fingerprint (hash) of the video's identifier, over HTTPS, with no cookies, account or sign-in; thousands of videos share any prefix, though the server still sees your internet address. Nothing is stored on disk. Risks: markings are made by volunteers and can be wrong or missing, and YouTube changes can stop it working. The data is shared under CC BY-NC-SA 4.0. Turn it off any time in Settings."
        case .spotifyHideAds: "StreamSetu will tell your web view to hide ad boxes and upgrade prompts on the Spotify page and not to contact Spotify's ad servers. It reads nothing from the page, your account or your cookies, and sends nothing anywhere. \(Self.spotifyRisks) Turn it off any time in Settings, then reload the page."
        case .spotifyMuteAds: "StreamSetu will run a small script inside the Spotify page that mutes the page's sound only while the player shows that an ad is playing, and puts the sound back when the ad ends. It does not skip, speed up or save anything, and reads nothing from your account or cookies. \(Self.spotifyRisks) Turn it off any time in Settings, then reload the page."
        }
    }

    /// The plain risks, shown on the first-open card and in both Spotify confirmations (one wording, so they never disagree).
    static let spotifyRisks = "Spotify's terms prohibit blocking or circumventing its ads. Using this can lead to Spotify suspending or terminating your account. It is best effort and can stop working at any time. Premium accounts see no ads. You choose this at your own risk."
}

/// Where the choices are kept. One place for both Settings and the first-open prompt, so they never disagree.
extension PageEnhancement {
    /// The service pages these apply to are only those whose definition lists them (`ProviderDefinition.pageEnhancements`).
    static func prompt(key id: ProviderID) -> String { "enhancement.prompt.\(id.rawValue)" }
}

/// The first-open card's words, per service.
extension PageEnhancement {
    static func promptCopy(for id: ProviderID) -> (title: String, detail: String) {
        if id == .spotify {
            return (Localized.string("Turn on the Spotify ad options?"),
                    Localized.string("Both options are off. You can change this any time in Settings.") + " " + Localized.string(spotifyRisks))
        }
        let full = Localized.string("Skip ads and sponsor segments on YouTube? Both are off. You can change this any time in Settings.")
        guard let r = full.range(of: "? ") ?? full.range(of: "?") else { return (full, "") }
        return (String(full[..<r.upperBound]).trimmingCharacters(in: .whitespaces), String(full[r.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
}
