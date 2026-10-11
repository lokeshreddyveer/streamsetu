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
