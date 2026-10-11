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
