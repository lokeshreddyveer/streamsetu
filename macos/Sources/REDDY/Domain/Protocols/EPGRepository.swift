import Foundation

protocol EPGRepository: Sendable {
    /// Current and next program per channel (by internal channel id), using the channel→guide mapping.
    func nowNext(channelIDs: [String], at date: Date) throws -> [String: [EPGProgram]]
    /// Programs overlapping [from, to) for several channels at once (TV Guide rows).
    func programs(channelIDs: [String], from: Date, to: Date) throws -> [String: [EPGProgram]]
    func program(id: Int64) throws -> EPGProgram?
    func guideCoverage(sourceID: UUID) throws -> (channels: Int, programs: Int, mapped: Int, lastUpdate: Date?)
    func guideChannels(sourceID: UUID) throws -> [(id: String, name: String)]
    func purge(before: Date) throws
    /// Programmes (current or upcoming) whose title matches, with the channel that carries them.
    func searchPrograms(term: String, sourceID: UUID?, from: Date, limit: Int) throws -> [(program: EPGProgram, channelID: String, channelName: String)]
    func mappedChannelIDs() throws -> Set<String>
}

/// What the guide holds for one channel around a moment: the current and next programmes, and which of them is on air.
struct ChannelNowNext: Sendable {
    let programmes: [EPGProgram]
    let now: EPGProgram?
}

extension EPGRepository {
    /// The one way "what is on now" is read for channels. Live TV, Home and the player all go through this, so they can never disagree about what is on.
    /// A channel the guide has nothing for is simply absent from the result.
    func lookup(channelIDs: [String], at date: Date = Date()) throws -> [String: ChannelNowNext] {
        guard !channelIDs.isEmpty else { return [:] }
        return try nowNext(channelIDs: channelIDs, at: date).mapValues { list in ChannelNowNext(programmes: list, now: list.first { $0.isLive(at: date) }) }
    }
}
