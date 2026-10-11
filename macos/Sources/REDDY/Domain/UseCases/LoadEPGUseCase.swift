import Foundation

struct LoadEPGUseCase: Sendable {
    let epg: EPGRepository

    func nowNext(channelIDs: [String], at date: Date = Date()) async throws -> [String: [EPGProgram]] {
        try await Task.detached { [epg] in try epg.nowNext(channelIDs: channelIDs, at: date) }.value
    }
    func window(channelIDs: [String], from: Date, to: Date) async throws -> [String: [EPGProgram]] {
        try await Task.detached { [epg] in try epg.programs(channelIDs: channelIDs, from: from, to: to) }.value
    }
}
