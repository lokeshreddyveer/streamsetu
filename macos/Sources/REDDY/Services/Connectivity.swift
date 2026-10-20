import Foundation
import Observation

/// Whether the device has a connection right now, for screens that change when it does not.
@MainActor @Observable
final class Connectivity {
    private(set) var online = true
    @ObservationIgnored private let watch = NetworkWatch()

    init() {
        watch.onChange = { [weak self] _, new in self?.online = new != .none }
        watch.start()
    }
}
