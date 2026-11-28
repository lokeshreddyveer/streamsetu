import Foundation

/// Undo and redo for the queue's removals, "clear" and reorders. One change is one step, except removals made within a few seconds of each
/// other, which merge into one step (one toast, one Undo). Undo puts rows back newest first, each after the row it followed, clamped to what
/// is in the queue now; rows that were already played are not restored. A new queue (a click on an album) starts a clean history.
struct MusicQueueHistory: Sendable {
    enum Op: Sendable, Equatable {
        /// One or more removals, oldest first; each inner array was removed in one go.
        case removed([[MusicQueue.RemovedRow]])
        case cleared([MusicQueue.RemovedRow])
        /// `wasAuto`: the row was an autoplay row before the move, which an Undo gives back to it.
        case moved(id: UUID, from: Int, to: Int, wasAuto: Bool)
    }

    /// What an undo or redo did, for the toast.
    enum Outcome: Equatable, Sendable {
        case removed(Int), cleared(Int), moved
    }

    struct Item: Sendable, Equatable { var op: Op; var at: Date }

    static let limit = 30
    /// Removals closer together than this merge into one step. It is as long as the toast with an action stays.
    static let mergeWindow: TimeInterval = 8

    private(set) var undoStack: [Item] = []
    private(set) var redoStack: [Item] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func reset() { undoStack = []; redoStack = [] }

    /// Records one removal. Returns how many rows the (possibly merged) step now holds.
    @discardableResult
    mutating func recordRemoval(_ rows: [MusicQueue.RemovedRow], at now: Date) -> Int {
        guard !rows.isEmpty else { return undoStack.last.map { Self.count($0.op) } ?? 0 }
        redoStack = []
        if let last = undoStack.last, case .removed(let groups) = last.op, now.timeIntervalSince(last.at) >= 0, now.timeIntervalSince(last.at) < Self.mergeWindow {
            let merged = Item(op: .removed(groups + [rows]), at: now)
            undoStack[undoStack.count - 1] = merged
            return Self.count(merged.op)
        }
        push(Item(op: .removed([rows]), at: now))
        return rows.count
    }

    mutating func recordClear(_ rows: [MusicQueue.RemovedRow], at now: Date) {
        guard !rows.isEmpty else { return }
        redoStack = []
        push(Item(op: .cleared(rows), at: now))
    }

    mutating func recordMove(id: UUID, from: Int, to: Int, wasAuto: Bool = false, at now: Date) {
        guard from != to else { return }
        redoStack = []
        push(Item(op: .moved(id: id, from: from, to: to, wasAuto: wasAuto), at: now))
    }

    private mutating func push(_ item: Item) {
        undoStack.append(item)
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
    }

    /// Reverses the newest step on `q`. Nil when there is nothing to undo.
    mutating func undo(on q: inout MusicQueue) -> Outcome? {
        guard let item = undoStack.popLast() else { return nil }
        redoStack.append(item)
        switch item.op {
        case .removed(let groups):
            var n = 0
            for g in groups.reversed() { n += q.restore(g) }
            return .removed(n)
        case .cleared(let rows): return .cleared(q.restore(rows))
        case .moved(let id, let from, _, let wasAuto):
            q.putBack(id: id, at: from, auto: wasAuto)
            return .moved
        }
    }

    /// Does the undone step again. Nil when there is nothing to redo.
    mutating func redo(on q: inout MusicQueue) -> Outcome? {
        guard let item = redoStack.popLast() else { return nil }
        undoStack.append(item)
        switch item.op {
        case .removed(let groups): return .removed(q.removeRows(ids: Set(groups.flatMap { $0 }.map(\.entry.id))))
        case .cleared(let rows): return .cleared(q.removeRows(ids: Set(rows.map(\.entry.id))))
        case .moved(let id, _, let to, _):
            q.moveRow(id: id, to: to)
            return .moved
        }
    }

    private static func count(_ op: Op) -> Int {
        switch op {
        case .removed(let g): g.reduce(0) { $0 + $1.count }
        case .cleared(let r): r.count
        case .moved: 1
        }
    }
}
