import Foundation
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var isSignedIn: Bool = Keychain.read("session") != nil
    @Published var instagramUsername: String?
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
    }

    func refreshProfile() async {
        guard let me = try? await APIClient.shared.request("GET", "v1/me") else { return }
        instagramUsername = (me["instagram"] as? [String: Any])?["username"] as? String
        if let c = me["claude"] as? [String: Any] {
            claudeUsedToday = c["usedToday"] as? Int ?? 0
            claudeDailyLimit = c["dailyLimit"] as? Int ?? 0
        }
    }

    func deleteAccount() async throws {
        try await APIClient.shared.request("DELETE", "v1/me")
        signOut()
    }
}
