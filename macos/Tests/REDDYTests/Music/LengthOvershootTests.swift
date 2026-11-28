import Foundation
import Testing
@testable import REDDY

@Suite struct LengthOvershootTests {
    @Test func withNoStatementFromTheStreamAnOvershootIsTrimmed() {
        let p = MusicStreamLength.plan(listed: 240, reported: 270, declared: nil)
        #expect(p.shown == 240 && p.endAt != nil)
    }

    @Test func aStreamThatItselfSaysItIsLongerIsNotCutShort() {
        // A 3-minute listing for a file that says it is 4.5 minutes: the song plays to its own end instead of being skipped three minutes in.
        let p = MusicStreamLength.plan(listed: 180, reported: 270, declared: 270)
        #expect(p.endAt == nil && p.shown == 270)
        // A file about twice as long is a different cut: still trimmed.
        let d = MusicStreamLength.plan(listed: 180, reported: 360, declared: 360)
        #expect(d.endAt != nil)
    }
}
