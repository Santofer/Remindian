import Foundation
import Combine

/// Singleton that handles `remindian://` URL scheme callbacks for OAuth flows.
class OAuthCallbackHandler: ObservableObject {
    static let shared = OAuthCallbackHandler()

    @Published var tickTickAuthCode: String?

    private init() {}

    /// Redact secret-bearing query items so a callback URL can be logged safely.
    ///
    /// `debug.log` is plaintext, sits in Application Support, and users routinely
    /// paste it into bug reports — logging `url.absoluteString` put the OAuth
    /// authorization code straight into it. Never log a raw callback URL.
    static func redactedForLogging(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "\(url.scheme ?? "?")://\(url.host ?? "?")"
        }
        let secretKeys: Set<String> = ["code", "token", "access_token", "refresh_token", "id_token", "state", "client_secret"]
        // Plain letters on purpose: URLComponents percent-encodes punctuation, so
        // "<redacted>" would render as "%3Credacted%3E" in the log.
        components.queryItems = components.queryItems?.map { item in
            secretKeys.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "REDACTED")
                : item
        }
        return components.string ?? "\(url.scheme ?? "?")://\(url.host ?? "?")"
    }

    /// Route an incoming URL to the appropriate handler.
    func handle(url: URL) {
        // Guard first, and never log the raw URL — it carries the auth code.
        guard url.scheme == "remindian" else { return }

        debugLog("[OAuth] Received callback: \(OAuthCallbackHandler.redactedForLogging(url))")

        switch url.host {
        case "oauth":
            handleOAuthCallback(url: url)
        default:
            debugLog("[OAuth] Unknown host: \(url.host ?? "nil")")
        }
    }

    private func handleOAuthCallback(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.pathComponents.dropFirst().first // e.g. "ticktick"

        switch path {
        case "ticktick":
            if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value {
                debugLog("[OAuth] TickTick auth code received")
                tickTickAuthCode = code
            } else {
                debugLog("[OAuth] TickTick callback missing code parameter")
            }
        default:
            debugLog("[OAuth] Unknown OAuth provider: \(path ?? "nil")")
        }
    }
}
