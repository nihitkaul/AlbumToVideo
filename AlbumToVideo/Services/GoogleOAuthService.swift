import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

actor GoogleOAuthService {
    private let config: GoogleOAuthConfig

    private static let scope = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"

    init(config: GoogleOAuthConfig) {
        self.config = config
    }

    func signIn(presentingWindow: NSWindow?) async throws -> KeychainTokenStore.StoredTokens {
        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.codeChallenge(for: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let authURL = components.url else {
            throw URLError(.badURL)
        }

        let callbackURL: URL
        if config.usesLoopbackRedirect {
            callbackURL = try await OAuthLoopbackReceiver.run(authURL: authURL, redirectURI: config.redirectURI)
        } else {
            guard let scheme = config.callbackURLScheme, !scheme.isEmpty else {
                throw NSError(domain: "AlbumToVideo", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "CALLBACK_URL_SCHEME is required when not using a loopback REDIRECT_URI."
                ])
            }
            let holder = OAuthWebSessionHolder(window: presentingWindow)
            callbackURL = try await holder.start(url: authURL, callbackScheme: scheme)
        }

        guard let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value
        else {
            throw NSError(domain: "AlbumToVideo", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Missing authorization code in callback."
            ])
        }

        return try await exchangeCode(code, verifier: verifier)
    }

    func refreshIfNeeded(_ tokens: KeychainTokenStore.StoredTokens) async throws -> KeychainTokenStore.StoredTokens {
        if let exp = tokens.accessExpiry, exp > Date().addingTimeInterval(120) {
            return tokens
        }
        guard let refresh = tokens.refreshToken else {
            throw NSError(domain: "AlbumToVideo", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Session expired. Please sign in again."
            ])
        }
        return try await refreshTokens(refreshToken: refresh)
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> KeychainTokenStore.StoredTokens {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientId,
            "code_verifier": verifier
        ]
        req.httpBody = Self.formURLEncoded(body).data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.throwIfHTTPError(resp, data: data)
        return try Self.parseTokenResponse(data)
    }

    private func refreshTokens(refreshToken: String) async throws -> KeychainTokenStore.StoredTokens {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientId
        ]
        req.httpBody = Self.formURLEncoded(body).data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.throwIfHTTPError(resp, data: data)
        var parsed = try Self.parseTokenResponse(data)
        // Google may omit refresh_token on refresh — keep prior
        if parsed.refreshToken == nil {
            parsed = KeychainTokenStore.StoredTokens(
                accessToken: parsed.accessToken,
                refreshToken: refreshToken,
                accessExpiry: parsed.accessExpiry
            )
        }
        return parsed
    }

    private static func parseTokenResponse(_ data: Data) throws -> KeychainTokenStore.StoredTokens {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let dict = obj, let access = dict["access_token"] as? String else {
            throw NSError(domain: "AlbumToVideo", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Invalid token response."
            ])
        }
        let refresh = dict["refresh_token"] as? String
        let expiresSeconds: Int? = (dict["expires_in"] as? Int)
            ?? (dict["expires_in"] as? Double).map { Int($0) }
        let exp = expiresSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }
        return KeychainTokenStore.StoredTokens(accessToken: access, refreshToken: refresh, accessExpiry: exp)
    }

    private static func throwIfHTTPError(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AlbumToVideo", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Token request failed (\(http.statusCode)): \(text)"
            ])
        }
    }

    private static func formURLEncoded(_ pairs: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }

    private static func randomURLSafeString(length: Int) -> String {
        let charset = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var result = ""
        result.reserveCapacity(length)
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        for i in 0 ..< length {
            result.append(charset[Int(bytes[i]) % charset.count])
        }
        return result
    }
}

private final class OAuthWebSessionHolder: NSObject, ASWebAuthenticationPresentationContextProviding {
    private weak var window: NSWindow?
    private var session: ASWebAuthenticationSession?

    init(window: NSWindow?) {
        self.window = window
    }

    func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            DispatchQueue.main.async {
                let s = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
                    self?.session = nil
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    guard let url else {
                        cont.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    cont.resume(returning: url)
                }
                self.session = s
                s.presentationContextProvider = self
                s.prefersEphemeralWebBrowserSession = false
                if !s.start() {
                    self.session = nil
                    cont.resume(throwing: NSError(domain: "AlbumToVideo", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Could not start sign-in session."
                    ]))
                }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

