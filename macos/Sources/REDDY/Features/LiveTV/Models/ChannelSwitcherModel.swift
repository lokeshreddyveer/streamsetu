import Foundation

/// Which channel is highlighted in the full-screen channel switcher. Pure, so the movement rules are testable.
struct ChannelSwitcherModel: Equatable {
    private(set) var count: Int
    private(set) var selected: Int

    init(count: Int, current: Int?) {
        self.count = max(0, count)
        self.selected = self.count == 0 ? 0 : min(max(0, current ?? 0), self.count - 1)
    }

    /// Moves the highlight, wrapping at both ends: the channel after the last is the first.
    mutating func move(by delta: Int) {
        guard count > 0 else { return }
        selected = ((selected + delta) % count + count) % count
    }

    /// The channels whose guide data is worth loading: the highlighted one and its neighbours.
    func window(radius: Int = 30) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        return max(0, selected - radius)..<min(count, selected + radius + 1)
    }
}

