import Foundation

struct GoogleOAuthConfig: Sendable {
    let clientId: String
    let redirectURI: String
    /// Used only for custom URL schemes (not loopback). When using `http://127.0.0.1:…`, leave empty.
    let callbackURLScheme: String?

    var usesLoopbackRedirect: Bool {
        let u = redirectURI.lowercased()
        return u.hasPrefix("http://127.0.0.1") || u.hasPrefix("http://localhost")
    }

    /// PKCE OAuth. Register the same `redirectURI` on your **Desktop** OAuth client in Google Cloud.
    static func loadFromBundle() throws -> GoogleOAuthConfig {
        guard let url = Bundle.main.url(forResource: "GoogleOAuthConfig", withExtension: "plist") else {
            throw ConfigError.missingPlist
        }
        let data = try Data(contentsOf: url)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let dict = obj,
              let clientId = dict["CLIENT_ID"] as? String,
              !clientId.isEmpty,
              let redirectURI = dict["REDIRECT_URI"] as? String,
              !redirectURI.isEmpty
        else {
            throw ConfigError.invalidPlist
        }
        let schemeRaw = (dict["CALLBACK_URL_SCHEME"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scheme = schemeRaw.isEmpty ? nil : schemeRaw
        let loopback = redirectURI.lowercased().hasPrefix("http://127.0.0.1")
            || redirectURI.lowercased().hasPrefix("http://localhost")
        if !loopback, scheme == nil {
            throw ConfigError.invalidPlist
        }
        return GoogleOAuthConfig(clientId: clientId, redirectURI: redirectURI, callbackURLScheme: scheme)
    }

    enum ConfigError: LocalizedError {
        case missingPlist
        case invalidPlist

        var errorDescription: String? {
            switch self {
            case .missingPlist:
                return "Missing GoogleOAuthConfig.plist. Copy GoogleOAuthConfig.example.plist and add your OAuth client ID."
            case .invalidPlist:
                return "GoogleOAuthConfig.plist is invalid: set CLIENT_ID, REDIRECT_URI, and for custom URL schemes set CALLBACK_URL_SCHEME. For Google Photos, use loopback http://127.0.0.1:8742/oauth2callback (see README)."
            }
        }
    }
}
