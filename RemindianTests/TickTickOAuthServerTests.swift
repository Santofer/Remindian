import XCTest
import Darwin
@testable import Remindian

/// Regression test for #61 — TickTick OAuth callback was racing against the
/// browser. `start()` used to dispatch the bind+listen to a background queue
/// and return immediately, so the OAuth redirect could arrive at the
/// loopback port before it was bound, surfacing as `ERR_CONNECTION_REFUSED`
/// in the user's browser.
///
/// The contract this test enforces: by the time `start()` returns
/// successfully, the port is open and a TCP connect succeeds immediately.
final class TickTickOAuthServerTests: XCTestCase {

    /// Use a non-default port so the test doesn't collide with a developer
    /// running the actual app at the same time.
    private let testPort: UInt16 = 23947

    override func tearDown() {
        super.tearDown()
        // Best-effort: free the test port if anything left it open.
    }

    /// The core regression for #61. After `start()` returns we MUST be able
    /// to TCP-connect to 127.0.0.1:port without retrying or sleeping. If this
    /// test ever flakes, the race condition is back.
    func testPortIsListeningImmediatelyAfterStart() throws {
        let server = TickTickOAuthServer(port: testPort) { _, _ in
            XCTFail("Code callback should not fire — we never deliver one")
        }
        defer { server.stop() }

        try server.start()

        // Connect to the port WITHOUT any delay.
        XCTAssertTrue(canConnect(toPort: testPort, on: "127.0.0.1"),
                      "Server must be listening before start() returns (#61).")
    }

    /// If the port is already in use, `start()` must throw rather than open
    /// the browser to a dead callback URL. Verifies the throwing contract.
    func testStartThrowsWhenPortAlreadyInUse() throws {
        // Occupy the port with a separate raw socket bound to it.
        let blocker = bindRawSocket(toPort: testPort)
        defer {
            if blocker >= 0 { close(blocker) }
        }
        guard blocker >= 0 else {
            throw XCTSkip("Could not occupy test port — environment-specific, skipping")
        }

        let server = TickTickOAuthServer(port: testPort) { _, _ in
            XCTFail("Code callback should not fire when bind fails")
        }

        XCTAssertThrowsError(try server.start()) { error in
            // Accept any TickTickOAuthServerError; specifically expect bindFailed.
            switch error {
            case TickTickOAuthServerError.bindFailed,
                 TickTickOAuthServerError.socketCreationFailed:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Try a synchronous TCP connect with a short timeout.
    private func canConnect(toPort port: UInt16, on host: String) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }

        // Short timeout — if the port is open, connect is immediate.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Bind a raw socket to `port` and start listening. Returns the file descriptor
    /// (which the caller must close) or -1 on failure. Used to simulate "port in use".
    private func bindRawSocket(toPort port: UInt16) -> Int32 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }

        var opt: Int32 = 0  // No SO_REUSEADDR — we want the second bind to fail.
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(s)
            return -1
        }
        Darwin.listen(s, 1)
        return s
    }
}
