import Testing
@testable import REDDY

@Suite struct VPNRulesTests {
    @Test func recognisesTunnelInterfaces() {
        #expect(VPNRules.looksLikeVPN(interfaces: ["en0", "utun3"]))
        #expect(VPNRules.looksLikeVPN(interfaces: ["ppp0"]) && VPNRules.looksLikeVPN(interfaces: ["IPSec0"]) && VPNRules.looksLikeVPN(interfaces: ["tun0"]))
        #expect(!VPNRules.looksLikeVPN(interfaces: ["en0", "en1", "lo0", "pdp_ip0"]))
        #expect(!VPNRules.looksLikeVPN(interfaces: []))
    }

    @Test func pausesOnlyWhenAVPNDropsDuringPlaybackAndTheSettingIsOn() {
        #expect(VPNRules.shouldPause(wasOn: true, isOn: false, enabled: true, playing: true))
        #expect(!VPNRules.shouldPause(wasOn: true, isOn: false, enabled: false, playing: true))
        #expect(!VPNRules.shouldPause(wasOn: true, isOn: false, enabled: true, playing: false))
        #expect(!VPNRules.shouldPause(wasOn: false, isOn: false, enabled: true, playing: true))   // never had one
        #expect(!VPNRules.shouldPause(wasOn: true, isOn: true, enabled: true, playing: true))
    }
}

@Suite struct FeedbackMessageTests {
    @Test func buildsAnEmailToTheSupportAddress() {
        let m = FeedbackMessage(kind: .problem, text: "  The guide is empty  ", diagnostics: "StreamSetu 2.2.2")
        #expect(m.subject.contains("Problem report") && m.body == "The guide is empty")
        #expect(m.fullText.contains("---") && m.fullText.hasSuffix("StreamSetu 2.2.2"))
        let url = m.mailtoURL?.absoluteString ?? ""
        #expect(url.hasPrefix("mailto:\(FeedbackMessage.address)") && url.contains("subject=") && !url.contains("StreamSetu%202.2.2%0A"))
    }

    @Test func emptyTextGetsAPrompt() {
        #expect(!FeedbackMessage(kind: .idea, text: "", diagnostics: nil).body.isEmpty)
        #expect(FeedbackMessage(kind: .idea, text: "x", diagnostics: nil).subject.contains("Idea"))
    }

    @Test func mailLinkIsKeptShort() {
        let m = FeedbackMessage(kind: .problem, text: String(repeating: "a", count: 10_000), diagnostics: nil)
        #expect((m.mailtoURL?.absoluteString.count ?? 0) < 2_000)
    }
}
