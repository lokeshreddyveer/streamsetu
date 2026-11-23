import Foundation

/// An optional, user-enabled addition to how a service's page behaves. Configuration only: a service lists the ones it supports in its
/// definition, and nothing runs unless the person turned it on and agreed to what it does. Every enhancement is off until then.
enum PageEnhancement: String, CaseIterable, Sendable, Identifiable {
    /// Removes the ad schedule from the page's player data, hides ad elements and skips an ad that still starts.
    case adSkip
    /// Skips the stretches of a video that people have marked as sponsor segments (asks a third-party service, by a short hash prefix).
    case sponsorSkip

    var id: String { rawValue }

    /// Bumped when what an enhancement does or sends changes, so an earlier agreement no longer counts.
    var consentVersion: Int { 1 }
    var enabledKey: String { "enhancement.\(rawValue).enabled" }
    var consentKey: String { "enhancement.\(rawValue).consent" }

    /// Plain English text of the setting; looked up in the language tables.
    var title: String {
        switch self {
        case .adSkip: "Skip ads"
        case .sponsorSkip: "Skip sponsor segments"
        }
    }
    var summary: String {
        switch self {
        case .adSkip: "Removes video ads from the page where it can. Off by default."
        case .sponsorSkip: "Jumps over parts of a video that people have marked as sponsor reads. Off by default."
        }
    }
    /// The explanation shown before turning it on: what it does, what is sent, and the risks.
    var consentTitle: String {
        switch self {
        case .adSkip: "Turn on ad skipping?"
        case .sponsorSkip: "Turn on sponsor skipping?"
        }
    }
    var consentMessage: String {
        switch self {
        case .adSkip: "StreamSetu will run a small script inside the YouTube page to remove the ad schedule from the player's data, hide ad boxes and skip an ad that still starts. Nothing is sent anywhere. Risks: YouTube changes often, so this can stop working or make a page misbehave; it may go against YouTube's terms; and ads are how creators and YouTube are paid. Turn it off any time in Settings, then reload the page."
        case .sponsorSkip: "While you watch a YouTube video, StreamSetu asks sponsor.ajay.app (the SponsorBlock project's server) which parts people marked as sponsor reads, and skips them with an Undo button. It sends only the first 4 characters of a fingerprint (hash) of the video's identifier, over HTTPS, with no cookies, account or sign-in; thousands of videos share any prefix, though the server still sees your internet address. Nothing is stored on disk. Risks: markings are made by volunteers and can be wrong or missing, and YouTube changes can stop it working. The data is shared under CC BY-NC-SA 4.0. Turn it off any time in Settings."
        }
    }
}

/// Where the choices are kept. One place for both Settings and the first-open prompt, so they never disagree.
extension PageEnhancement {
    /// The service pages these apply to are only those whose definition lists them (`ProviderDefinition.pageEnhancements`).
    static func prompt(key id: ProviderID) -> String { "enhancement.prompt.\(id.rawValue)" }
}
