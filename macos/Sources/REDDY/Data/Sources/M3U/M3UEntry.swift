import Foundation

struct M3UEntry: Sendable, Equatable {
    var name: String
    var url: String
    var duration: Double = -1
    var attributes: [String: String] = [:]
    var group: String?

    var tvgID: String? { attributes["tvg-id"].nilIfEmpty }
    var tvgName: String? { attributes["tvg-name"].nilIfEmpty }
    var logo: String? { attributes["tvg-logo"].nilIfEmpty }
    var groupTitle: String? { (attributes["group-title"].nilIfEmpty) ?? group.nilIfEmpty }
    var language: String? { attributes["tvg-language"].nilIfEmpty }
    var country: String? { attributes["tvg-country"].nilIfEmpty }
}

struct M3UHeader: Sendable, Equatable {
    var epgURLs: [String] = []
}
