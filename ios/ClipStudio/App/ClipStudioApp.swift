import SwiftUI

@main
struct ClipStudioApp: App {
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: SessionStore

    var body: some View {
        Group {
            if session.isSignedIn {
                HomeView()
            } else {
                SignInView()
            }
        }
        .animation(.default, value: session.isSignedIn)
    }
}

enum Theme {
    static let accent = Color(red: 0.85, green: 0.64, blue: 0.25)
}
