import Foundation
import Network

// One TCP connection carrying length-prefixed frames. It refuses any peer that is not on a private network, and it never buffers more
// than one maximum frame. All callbacks run on the main queue, so the rest of the feature stays on the main actor.

enum MusicRemoteNetwork {
    static func isPrivate(_ endpoint: NWEndpoint?) -> Bool { MusicNetworkPolicy.isPrivate(endpoint) }

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.noDelay = true
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = false
        return p
    }
}

@MainActor
final class MusicRemoteTransport {
    private let connection: NWConnection
    private var buffer = MusicRemoteFrameBuffer()
    private var finished = false
    var onReady: (@MainActor () -> Void)?
    var onFrame: (@MainActor (Data) -> Void)?
    var onClosed: (@MainActor (MusicRemoteError?) -> Void)?

    init(connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            // Fail closed: if the resolved address is not a private one, the connection is dropped before any byte is read.
            let remote = connection.currentPath?.remoteEndpoint ?? connection.endpoint
            guard MusicRemoteNetwork.isPrivate(remote) else { close(.privateNetworkOnly); return }
            receive()
            onReady?()
        case .failed, .cancelled:
            close(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                if let data, !data.isEmpty {
                    do {
                        for frame in try self.buffer.append(data) {
                            self.onFrame?(frame)
                            if self.finished { return }
                        }
                    } catch let e as MusicRemoteError { self.close(e); return } catch { self.close(.malformed("frame")); return }
                }
                if error != nil || isComplete { self.close(nil); return }
                self.receive()
            }
        }
    }

    func send(_ body: Data) {
        guard !finished, let framed = try? MusicRemoteFraming.encode(body) else { return }
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            if error != nil { MainActor.assumeIsolated { self?.close(nil) } }
        })
    }

    func close(_ reason: MusicRemoteError? = nil) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?(reason)
    }
}
