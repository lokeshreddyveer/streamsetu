import Foundation
import Network

/// A TCP listener for tests that can be reached only from this computer (127.0.0.1). A listener on every interface is reachable from the network while the test runs, and a firewall
/// that blocks incoming connections (macOS can) makes a connection to it from this same computer time out, which is how three network tests started to fail with no code change.
func loopbackListener() throws -> NWListener {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    return try NWListener(using: parameters)
}
