import Foundation

enum SchemaV26 {
    /// Nothing to change. Development builds used version 26 for a feature that was withdrawn before release; the number stays taken so versions remain consecutive and a
    /// database that is already at 26 moves on to 27, which removes what that feature created.
    static let sql = "SELECT 1;"
}
