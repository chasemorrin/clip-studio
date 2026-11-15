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
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Clips", systemImage: "film.stack") }
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.85, green: 0.64, blue: 0.25)
}
