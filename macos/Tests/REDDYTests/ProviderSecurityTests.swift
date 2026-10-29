import Testing
import Foundation
@testable import REDDY

@Suite("A login for an unencrypted server is never saved quietly") struct ProviderSecurityTests {
    @Test func aLoginForAPlainHTTPServerOnTheInternetAsksFirst() {
        #expect(ProviderSecurity.plainHTTPWarning(address: "http://provider.example:8080", hasLogin: true) != nil)
        #expect(ProviderSecurity.plainHTTPWarning(address: "provider.example:8080", hasLogin: true) != nil, "no scheme means plain http")
    }

    @Test func anEncryptedAddressNeverAsks() {
        #expect(ProviderSecurity.plainHTTPWarning(address: "https://provider.example", hasLogin: true) == nil)
    }

    @Test func noLoginNoWarning() {
        #expect(ProviderSecurity.plainHTTPWarning(address: "http://provider.example/list.m3u", hasLogin: false) == nil)
        #expect(ProviderSecurity.plainHTTPWarning(address: "", hasLogin: true) == nil)
    }

    @Test func aLoginInsideTheAddressCountsAsALogin() {
        #expect(ProviderSecurity.plainHTTPWarning(address: "http://provider.example/get.php?username=me&password=pw", hasLogin: false) != nil)
        #expect(ProviderSecurity.plainHTTPWarning(address: "http://me:pw@provider.example/list.m3u", hasLogin: false) != nil)
        #expect(ProviderSecurity.plainHTTPWarning(address: "http://provider.example/list.m3u?type=m3u", hasLogin: false) == nil)
    }

    @Test func aServerOnThisNetworkDoesNotAsk() {
        for host in ["192.168.1.50", "10.0.0.2", "172.16.4.9", "172.31.255.1", "127.0.0.1", "localhost", "nas.local", "169.254.3.3"] {
            #expect(ProviderSecurity.plainHTTPWarning(address: "http://\(host):8096", hasLogin: true) == nil, "\(host)")
        }
        #expect(ProviderSecurity.plainHTTPWarning(address: "http://172.32.0.1", hasLogin: true) != nil, "172.32 is not a private range")
        #expect(ProviderSecurity.plainHTTPWarning(address: "http://192.169.0.1", hasLogin: true) != nil)
    }

    @MainActor @Test func theFormAsksOnceAndRemembersTheAnswerForThatAddress() {
        let vm = AddSourceViewModel()
        vm.kind = .xtream; vm.server = "http://provider.example:8080"; vm.username = "me"; vm.password = "pw"
        #expect(vm.plainHTTPWarning != nil)
        vm.acceptPlainHTTP()
        #expect(vm.plainHTTPWarning == nil, "agreed for this address")
        vm.server = "http://other.example:8080"
        #expect(vm.plainHTTPWarning != nil, "another address asks again")
    }

    @MainActor @Test func aTunerOrAFileNeverAsks() {
        let vm = AddSourceViewModel()
        vm.kind = .hdhomerun; vm.server = "http://tuner.example"
        #expect(vm.plainHTTPWarning == nil)
        vm.kind = .m3uFile
        #expect(vm.plainHTTPWarning == nil)
    }
}
