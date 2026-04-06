import Foundation

struct GoogleOAuthConfig: Sendable {
    let clientId: String
    let redirectURI: String
    let callbackURLScheme: String

    /// PKCE OAuth for installed apps. Register the same `redirectURI` in Google Cloud Console → Credentials → your OAuth client.
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
              !redirectURI.isEmpty,
              let scheme = dict["CALLBACK_URL_SCHEME"] as? String,
              !scheme.isEmpty
        else {
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
                return "GoogleOAuthConfig.plist is invalid or still contains placeholder values."
            }
        }
    }
}
