import Foundation

// The section-loading protocol pages use (section 4.4). A page is a list of sections (credits, cast, "more by this composer"...). Each section has
// its own state, so the page renders what it has and fills the rest in, and never blanks while a section refreshes.

enum MusicSectionPhase: Sendable, Equatable {
    case idle
    /// Loading; `items` still holds what was cached, if anything.
    case loading
    /// Some items have arrived and more are coming.
    case partial
    case loaded
    /// Finished with nothing to show.
    case empty
    /// Failed; `items` still holds the stale ones, if any.
    case failed
}

/// Where a section's items came from and why they are shown (a "via" line: "Because Mukesh sang in Awaara").
struct MusicSectionProvenance: Hashable, Sendable {
    var source: MusicSourceID?
    var status: EdgeStatus?
    var confidence: Float?
    var retrievedAt: Date?
    var note: String?
    init(source: MusicSourceID? = nil, status: EdgeStatus? = nil, confidence: Float? = nil, retrievedAt: Date? = nil, note: String? = nil) {
        self.source = source; self.status = status; self.confidence = confidence; self.retrievedAt = retrievedAt; self.note = note
    }
}

/// What a section loader hands back, whole or as a partial. Items must be Sendable values (the loader checks nothing: `AnyHashable` is not marked Sendable).
struct MusicSectionResult: @unchecked Sendable {
    var items: [AnyHashable]
    var provenance: [MusicSectionProvenance]
    /// One line saying why these items are here, in the person's words.
    var explanation: String?
    init(items: [AnyHashable] = [], provenance: [MusicSectionProvenance] = [], explanation: String? = nil) {
        self.items = items; self.provenance = provenance; self.explanation = explanation
    }
}

/// The state of one section, as a page reads it.
struct MusicEntitySection: @unchecked Sendable, Equatable {
    var key: String
    var phase: MusicSectionPhase = .idle
    var items: [AnyHashable] = []
    var provenance: [MusicSectionProvenance] = []
    var explanation: String?
    var errorMessage: String?

    init(key: String) { self.key = key }

    /// The items as one type (a page knows what its section holds); items of another type are left out.
    func items<T: Hashable>(_ type: T.Type) -> [T] { items.compactMap { $0.base as? T } }
}

/// Reports items as they arrive, so a section shows its first rows before the last ones are in.
struct MusicSectionReporter: Sendable {
    let send: @Sendable (MusicSectionResult) async -> Void
    func partial(_ r: MusicSectionResult) async { await send(r) }
}

/// One section's loader. A page (or the Related tab) supplies it; the model runs it once however many views ask. A loader reads the graph through
/// the store handed to it and must never touch the player.
protocol MusicEntitySectionLoader: Sendable {
    /// Stable per section kind, for example `credits`, `cast`, `moreByComposers`, `related`.
    var key: String { get }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult
}

/// A loader from a closure, for tests and small sections.
struct MusicClosureSectionLoader: MusicEntitySectionLoader {
    let key: String
    let body: @Sendable (MusicEntityID, any MusicGraphStoring, MusicSectionReporter) async throws -> MusicSectionResult
    init(key: String, _ body: @escaping @Sendable (MusicEntityID, any MusicGraphStoring, MusicSectionReporter) async throws -> MusicSectionResult) {
        self.key = key; self.body = body
    }
    func load(entity: MusicEntityID, store: any MusicGraphStoring, report: MusicSectionReporter) async throws -> MusicSectionResult {
        try await body(entity, store, report)
    }
}
