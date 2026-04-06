import AppKit
import Foundation
import Network

/// Receives OAuth redirect on `http://127.0.0.1` / `http://localhost` (works with **Desktop** OAuth clients + sensitive Google scopes).
enum OAuthLoopbackReceiver {
    /// Listens on the port from `redirectURI`, then opens `authURL`. Returns the callback URL including `?code=...`.
    static func run(authURL: URL, redirectURI: String) async throws -> URL {
        guard let expected = URL(string: redirectURI),
              let host = expected.host,
              host == "127.0.0.1" || host.lowercased() == "localhost",
              expected.scheme?.lowercased() == "http",
              let port = expected.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port))
        else {
            throw NSError(domain: "AlbumToVideo", code: 50, userInfo: [
                NSLocalizedDescriptionKey:
                    "Loopback redirect must be http://127.0.0.1:PORT/ or http://127.0.0.1:PORT/oauth2callback (PORT required)."
            ])
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            ReceiverSession(port: nwPort, listenHost: host, authURL: authURL, continuation: cont).start()
        }
    }
}

private final class ReceiverSession: @unchecked Sendable {
    private var listener: NWListener?
    private var resumed = false
    private let lock = NSLock()
    private let port: UInt16
    private let listenHost: String
    private let authURL: URL
    private let continuation: CheckedContinuation<URL, Error>

    init(port: NWEndpoint.Port, listenHost: String, authURL: URL, continuation: CheckedContinuation<URL, Error>) {
        self.port = port.rawValue
        self.listenHost = listenHost
        self.authURL = authURL
        self.continuation = continuation
    }

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            continuation.resume(throwing: NSError(domain: "AlbumToVideo", code: 51, userInfo: [
                NSLocalizedDescriptionKey: "Invalid port."
            ]))
            return
        }
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(self.authURL)
                    }
                case let .failed(error):
                    self.finish(.failure(error))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }

            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func callbackBaseURL() -> String {
        if listenHost.lowercased() == "localhost" {
            return "http://localhost:\(port)"
        }
        return "http://127.0.0.1:\(port)"
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                finish(.failure(error))
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty,
                  let raw = String(data: data, encoding: .utf8)
            else {
                connection.cancel()
                return
            }
            guard let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first else {
                respondAndClose(connection: connection, status: 400, body: "Bad request")
                return
            }
            let line = String(firstLine)
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 2, parts[0] == "GET" else {
                respondAndClose(connection: connection, status: 400, body: "Expected GET")
                return
            }
            let resource = parts[1]
            let base = callbackBaseURL()
            guard let url = URL(string: base + (resource.hasPrefix("/") ? resource : "/" + resource))
            else {
                respondAndClose(connection: connection, status: 400, body: "Bad path")
                return
            }
            let hasCode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains { $0.name == "code" && !($0.value ?? "").isEmpty } == true
            guard hasCode else {
                respondAndClose(connection: connection, status: 400, body: "Missing ?code=")
                connection.cancel()
                return
            }
            let html = "<!DOCTYPE html><html><body><p>Sign-in complete. You can close this window.</p></body></html>"
            respondAndClose(connection: connection, status: 200, body: html)
            connection.cancel()
            listener?.cancel()
            listener = nil
            finish(.success(url))
        }
    }

    private func respondAndClose(connection: NWConnection, status: Int, body: String) {
        let data = body.data(using: .utf8) ?? Data()
        let reason = status == 200 ? "OK" : "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(data.count)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(data)
        connection.send(content: out, isComplete: true, completion: .idempotent)
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        switch result {
        case let .success(url):
            continuation.resume(returning: url)
        case let .failure(err):
            continuation.resume(throwing: err)
        }
    }
}
