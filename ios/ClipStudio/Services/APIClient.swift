import Foundation

struct APIError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Talks to the Cloudflare server.
final class APIClient {
    static let shared = APIClient()
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 150   // Claude can take a while with images
        cfg.timeoutIntervalForResource = 600
        session = URLSession(configuration: cfg)
    }

    var token: String? { Keychain.read("session") }

    /// Sends JSON (any JSONSerialization-compatible value) and returns the decoded JSON object.
    @discardableResult
    func request(_ method: String, _ path: String, json: Any? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: Config.serverURL.appendingPathComponent(path))
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError(code: "offline", message: "Couldn't reach the server. Check your connection and try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200..<300).contains(status) {
            let err = obj["error"] as? [String: Any]
            let apiError = APIError(code: err?["code"] as? String ?? "http_\(status)",
                                    message: err?["message"] as? String ?? "The server returned an error (\(status)).")
            if status == 401 {
                await MainActor.run { NotificationCenter.default.post(name: .signedOut, object: nil) }
            }
            throw apiError
        }
        return obj
    }

    // MARK: Sign in

    func signInWithApple(identityToken: String) async throws -> String {
        let r = try await request("POST", "v1/auth/apple", json: ["identityToken": identityToken])
        guard let t = r["token"] as? String else { throw APIError(code: "bad_response", message: "Sign-in didn't return a login.") }
        return t
    }

    func signInWithTestPassword(_ key: String) async throws -> String {
        let r = try await request("POST", "v1/auth/dev", json: ["key": key])
        guard let t = r["token"] as? String else { throw APIError(code: "bad_response", message: "Sign-in didn't return a login.") }
        return t
    }

    // MARK: Claude

    /// content: an array of Claude content blocks (text and image dictionaries).
    func askClaude(system: String, content: [[String: Any]], maxTokens: Int = 3000) async throws -> String {
        let r = try await request("POST", "v1/claude", json: [
            "system": system,
            "messages": [["role": "user", "content": content]],
            "maxTokens": maxTokens,
        ])
        return r["text"] as? String ?? ""
    }
}

extension Notification.Name {
    static let signedOut = Notification.Name("ClipStudioSignedOut")
}
