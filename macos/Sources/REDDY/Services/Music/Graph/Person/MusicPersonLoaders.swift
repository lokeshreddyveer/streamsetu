import Foundation

// Section loaders for a person page, in the entity model's protocol (section 4.4): each runs once per entity however many views hold it, reports
// partial results, and is cancelled when the last lease goes. They read the graph only through the store handed to them.

/// The header's data and the role summary: what the page needs for its first paint after the entity row.
struct MusicPersonProfile: Hashable, Sendable {
    var header: MusicPersonHeaderData
    var roles: MusicPersonRoleSummary
}

struct MusicPersonProfileLoader: MusicEntitySectionLoader {
    static let sectionKey = "person.profile"
    var key: String { Self.sectionKey }

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        guard let snap = try await store.entity(entity) else { return MusicSectionResult() }
        let aliases = (try? await store.aliases(of: entity)) ?? []
        let ids = (try? await store.externalIDs(of: entity)) ?? []
        let header = MusicPersonHeaderData.build(snapshot: snap, aliases: aliases, externalIDs: ids)
        await report.partial(MusicSectionResult(items: [MusicPersonProfile(header: header, roles: .empty)]))
        try Task.checkCancellation()
        let reader = MusicPersonReader(store: store, person: entity)
        let roles = await reader.roleSummary()
        return MusicSectionResult(items: [MusicPersonProfile(header: header, roles: roles)])
    }
}

/// One role's sections.
struct MusicPersonViewLoader: MusicEntitySectionLoader {
    let view: MusicPersonView
    static func key(_ v: MusicPersonView) -> String { "person.view." + v.rawValue }
    var key: String { Self.key(view) }

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let reader = MusicPersonReader(store: store, person: entity)
        let v = view
        let result = try await reader.build(v) { partial in
            guard !partial.isEmpty else { return }
            await report.partial(MusicSectionResult(items: [partial]))
        }
        return MusicSectionResult(items: result.isEmpty ? [] : [result])
    }
}

/// Members of a group (only when a source listed them) or the groups a person belongs to.
struct MusicPersonGroupLoader: MusicEntitySectionLoader {
    static let sectionKey = "person.groups"
    var key: String { Self.sectionKey }

    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        let reader = MusicPersonReader(store: store, person: entity)
        let items: [MusicPersonSection]
        if entity.kind == .group { items = [MusicPersonSection(.members, await reader.membersOfGroup()), MusicPersonSection(.soloCareers, await reader.soloCareers())] }
        else { items = [MusicPersonSection(.memberOf, await reader.groupsOfPerson())] }
        let influence = [MusicPersonSection(.influencedBy, await reader.influences()), MusicPersonSection(.influenced, await reader.influenced())]
        return MusicSectionResult(items: (items + influence).filter { !$0.entries.isEmpty })
    }
}
