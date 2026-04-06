import Foundation

enum GooglePhotosPickerError: LocalizedError {
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case let .http(code, body):
            return "Photos API error (\(code)): \(body)"
        case let .decoding(msg):
            return "Could not read API response: \(msg)"
        }
    }
}

struct PickerSessionDTO: Codable {
    let id: String?
    let pickerUri: String?
    let mediaItemsSet: Bool?
    let pollingConfig: PickerPollingConfigDTO?
}

struct PickerPollingConfigDTO: Codable {
    let pollInterval: String?
    let timeoutIn: String?
}

struct PickedMediaItemDTO: Codable {
    let id: String
    let type: String?
    let mediaFile: PickerMediaFileDTO?
}

struct PickerMediaFileDTO: Codable {
    let baseUrl: String
    let mimeType: String
    let filename: String?
}

struct ListPickedMediaResponseDTO: Codable {
    let mediaItems: [PickedMediaItemDTO]?
    let nextPageToken: String?
}

enum GooglePhotosPickerClient {
    private static let base = "https://photospicker.googleapis.com/v1"

    static func createSession(accessToken: String) async throws -> PickerSessionDTO {
        var req = URLRequest(url: URL(string: "\(base)/sessions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try throwIfBad(resp, data: data)
        return try decode(PickerSessionDTO.self, from: data)
    }

    static func getSession(id: String, accessToken: String) async throws -> PickerSessionDTO {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var req = URLRequest(url: URL(string: "\(base)/sessions/\(enc)")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try throwIfBad(resp, data: data)
        return try decode(PickerSessionDTO.self, from: data)
    }

    static func deleteSession(id: String, accessToken: String) async throws {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var req = URLRequest(url: URL(string: "\(base)/sessions/\(enc)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try throwIfBad(resp, data: data)
    }

    static func listPickedMedia(sessionId: String, pageToken: String?, accessToken: String) async throws -> ListPickedMediaResponseDTO {
        var comp = URLComponents(string: "\(base)/mediaItems")!
        var items = [URLQueryItem(name: "sessionId", value: sessionId)]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        comp.queryItems = items
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try throwIfBad(resp, data: data)
        return try decode(ListPickedMediaResponseDTO.self, from: data)
    }

    static func parsePollIntervalSeconds(_ duration: String?) -> TimeInterval {
        guard let raw = duration?.trimmingCharacters(in: .whitespacesAndNewlines), raw.hasSuffix("s") else {
            return 2
        }
        let num = String(raw.dropLast())
        guard let v = Double(num) else { return 2 }
        return max(0.5, min(v, 30))
    }

    private static func throwIfBad(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GooglePhotosPickerError.http(http.statusCode, text)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(800), encoding: .utf8) ?? ""
            throw GooglePhotosPickerError.decoding("\(error.localizedDescription) — \(snippet)")
        }
    }
}
