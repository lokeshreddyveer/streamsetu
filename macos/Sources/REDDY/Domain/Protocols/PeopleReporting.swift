import Foundation

/// A provider whose series list already names the cast and directors: the names are handed over once, after the list was read.
protocol PeopleReporting: AnyObject {
    /// Series id → the names of the people in it. Empties itself, so each list is handed over once.
    func takeSeriesPeople() -> [String: [String]]
}
