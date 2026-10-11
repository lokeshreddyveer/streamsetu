import Foundation

enum XtreamError: LocalizedError, Sendable {
    case authFailed
    case inactive(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .authFailed: "The provider rejected the login. Check the username and password."
        case .inactive(let s): "The account is not active (\(s))."
        case .invalidResponse(let m): "The server's reply wasn't in the expected format. \(m)"
        }
    }
}
