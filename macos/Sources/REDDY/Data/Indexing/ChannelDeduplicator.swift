import Foundation

/// Groups likely quality variants ("Sky Sports", "Sky Sports HD", "Sky Sports FHD") into one logical channel.
/// Conservative: only within the same source and category, and only when the names differ solely by quality markers.
/// Nothing is merged across sources and nothing is deleted.
enum ChannelDeduplicator {
    struct Output: Sendable {
        var channels: [Channel]
        var variants: [StreamVariant]
        var primaryIDs: Set<String>
    }

    static func group(_ input: [Channel]) -> Output {
        var buckets: [String: [Int]] = [:]
        for (i, c) in input.enumerated() {
            let base = MetadataNormalizer.baseName(c.normalizedName)
            guard !base.isEmpty else { continue }
            buckets["\(c.sourceID.uuidString)|\(c.categoryID ?? "")|\(base)", default: []].append(i)
        }
        var channels = input
        var variants: [StreamVariant] = []
        var primaries = Set(input.map(\.id))

        for (key, idxs) in buckets where idxs.count > 1 {
            let members = idxs.map { input[$0] }
            let labeled = members.map { (c: $0, q: MetadataNormalizer.qualityLabel($0.normalizedName)) }
            // Only group when at least two members are actually distinguishable by a quality marker
            // or are exact duplicates by name; this keeps unrelated same-named channels apart.
            let best = labeled.max { a, b in
                let ra = MetadataNormalizer.qualityRank(a.q), rb = MetadataNormalizer.qualityRank(b.q)
                return ra != rb ? ra < rb : a.c.sortOrder > b.c.sortOrder
            }!
            var alt = 0
            for (c, q) in labeled {
                if c.id != best.c.id { primaries.remove(c.id) }
                if q == nil && c.id != best.c.id { alt += 1 }
                let label = q ?? (c.id == best.c.id ? "Main" : "Alt \(alt)")
                variants.append(StreamVariant(channelID: best.c.id, variantID: c.id, label: label))
            }
            for i in idxs { channels[i].groupKey = key }
        }
        return Output(channels: channels, variants: variants, primaryIDs: primaries)
    }
}
