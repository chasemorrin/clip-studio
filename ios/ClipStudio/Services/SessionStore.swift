import Foundation
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var isSignedIn: Bool = Keychain.read("session") != nil
    @Published var instagramUsername: String?
    /// The connected YouTube channel's name, or nil.
    @Published var youtubeChannel: String?
    @Published var youtubeHandle: String?
    /// False until the Google client ID and secret are on the server.
    @Published var youtubeAvailable = false
    @Published var claudeUsedToday: Int = 0
    @Published var claudeDailyLimit: Int = 0

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .signedOut, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.signOut() }
        }
    }

    func signedIn(token: String) {
        Keychain.write("session", token)
        isSignedIn = true
        Task { await refreshProfile() }
    }

    func signOut() {
        Keychain.delete("session")
        isSignedIn = false
        instagramUsername = nil
        youtubeChannel = nil
        youtubeHandle = nil
    }

    func refreshProfile() async {
        guard let me = try? await APIClient.shared.request("GET", "v1/me") else { return }
        instagramUsername = (me["instagram"] as? [String: Any])?["username"] as? String
        let yt = me["youtube"] as? [String: Any]
        youtubeChannel = yt.map { $0["channelTitle"] as? String ?? "YouTube" }
        youtubeHandle = yt?["handle"] as? String
        youtubeAvailable = me["youtubeAvailable"] as? Bool ?? false
        if let c = me["claude"] as? [String: Any] {
            claudeUsedToday = c["usedToday"] as? Int ?? 0
            claudeDailyLimit = c["dailyLimit"] as? Int ?? 0
        }
    }

    /// Whether new clips should go to YouTube too (Settings), when a channel is connected.
    var youtubeByDefault: Bool {
        youtubeChannel != nil && (UserDefaults.standard.object(forKey: "youtubeByDefault") as? Bool ?? true)
    }

    func deleteAccount() async throws {
        try await APIClient.shared.request("DELETE", "v1/me")
        signOut()
    }
}
