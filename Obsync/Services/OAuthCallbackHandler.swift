import Foundation
import Combine
import Security

/// Singleton that handles OAuth callbacks (loopback HTTP + `remindian://` URL
/// scheme) for OAuth flows.
class OAuthCallbackHandler: ObservableObject {
    static let shared = OAuthCallbackHandler()

    @Published var tickTickAuthCode: String?

    /// The `state` value for the TickTick flow currently in progress, if any.
    ///
    /// OAuth 2.0's `state` binds the callback to the request *this* app started.
    /// Without it, any local process or web page could hit the loopback port (or
    /// the `remindian://` scheme) with an attacker's `code` and silently bind the
    /// user's app to the attacker's account (GHSA-3q2g-hmqg-qj5r, H3 + L1). A
    /// callback whose `state` doesn't match a flow we started is rejected.
    private var pendingTickTickState: String?
    private let stateLock = NSLock()

    private init() {}

    // MARK: - CSRF state

    /// Start a TickTick OAuth flow: mint a fresh random `state`, remember it, and
    /// return it to be put in the authorization URL.
    func beginTickTickFlow() -> String {
        let state = OAuthCallbackHandler.randomState()
        stateLock.lock()
        pendingTickTickState = state
        stateLock.unlock()
        return state
    }

    /// Validate a callback's `state` against the pending flow, consuming it so a
    /// value can't be replayed. Returns false when there is no flow in progress or
    /// the value doesn't match (constant-time compare).
    func consumeTickTickState(_ received: String?) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let expected = pendingTickTickState else { return false }
        guard let received, OAuthCallbackHandler.constantTimeEquals(received, expected) else { return false }
        pendingTickTickState = nil   // one-time use
        return true
    }

    /// A URL-safe, cryptographically random token.
    static func randomState(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            // Extremely unlikely; fall back to the system RNG rather than a weak state.
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Length-independent, content-constant-time string comparison.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<x.count {
            diff |= Int(x[i]) ^ Int(y[i < y.count ? i : 0])
        }
        return diff == 0
    }

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
            let items = components?.queryItems
            let code = items?.first(where: { $0.name == "code" })?.value
            let state = items?.first(where: { $0.name == "state" })?.value
            guard let code else {
                debugLog("[OAuth] TickTick callback missing code parameter")
                return
            }
            // Reject any callback that isn't bound to the flow this app started (H3/L1).
            guard consumeTickTickState(state) else {
                debugLog("[OAuth] TickTick callback rejected: state mismatch or no flow in progress")
                return
            }
            debugLog("[OAuth] TickTick auth code received")
            tickTickAuthCode = code
        default:
            debugLog("[OAuth] Unknown OAuth provider: \(path ?? "nil")")
        }
    }
}
