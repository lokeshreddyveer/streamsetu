import Testing
import Foundation
@testable import REDDY

@Suite struct SecureDNSTests {
    @Test func anAnswerIsReadIntoAddresses() {
        let json = #"{"Status":0,"Answer":[{"name":"x.com","type":5,"data":"y.com."},{"name":"y.com","type":1,"data":"93.184.216.34"},{"type":1,"data":"0.0.0.0"}]}"#
        #expect(SecureDNS.parse(Data(json.utf8)) == ["93.184.216.34"])
        #expect(SecureDNS.parse(Data("nope".utf8)).isEmpty)
        #expect(SecureDNS.parse(Data(#"{"Status":3}"#.utf8)).isEmpty)
    }

    @Test func blockedAndPrivateAddressesAreNotUsed() {
        for ip in ["0.0.0.0", "127.0.0.1", "10.1.2.3", "192.168.1.5", "169.254.1.1", "300.1.1.1", "abc"] { #expect(!SecureDNS.isUsable(ip), "\(ip)") }
        #expect(SecureDNS.isUsable("45.12.200.9"))
    }

    @Test func theNameIsSwappedForTheAddressAndKeptAsHostHeader() {
        let r = SecureDNS.rewrite(URL(string: "http://server-1.example:8080/series/u/p/123.mp4?x=1")!, to: "45.12.200.9")
        #expect(r?.url.absoluteString == "http://45.12.200.9:8080/series/u/p/123.mp4?x=1")
        #expect(r?.hostHeader == "server-1.example:8080")
        #expect(SecureDNS.rewrite(URL(string: "https://server-1.example/a")!, to: "1.2.3.4") == nil)
        #expect(SecureDNS.rewrite(URL(string: "http://1.2.3.4:80/a")!, to: "5.6.7.8") == nil)
    }
}
