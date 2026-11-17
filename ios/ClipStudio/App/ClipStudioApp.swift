import SwiftUI

@main
struct ClipStudioApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var posts = PostsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(posts)
                .tint(Theme.accent)
                .onAppear { KeyboardDismiss.install() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: SessionStore

    var body: some View {
        Group {
            if session.isSignedIn {
                MainTabs()
            } else {
                SignInView()
            }
        }
        .animation(.default, value: session.isSignedIn)
    }
}

struct MainTabs: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Clips", systemImage: "film.stack") }
                .tag(0)
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        // Tapping the home-screen widget opens the Calendar.
        .onOpenURL { url in
            if url.scheme == "clipstudio", url.host() == "calendar" { tab = 1 }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.85, green: 0.64, blue: 0.25)
}
