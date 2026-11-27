import AVFoundation
import SwiftUI

@main
struct ClipStudioApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var posts = PostsStore()

    init() {
        // Play video sound even with the ringer switch on silent (like other video apps).
        // Other audio, like music, pauses only when a video actually plays.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

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
    @ObservedObject private var ideaLink = IdeaLink.shared

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Clips", systemImage: "film.stack") }
                .tag(0)
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(1)
            IdeasView()
                .tabItem { Label("Ideas", systemImage: "lightbulb") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        // "Add media" on an idea opens the Clips tab.
        .onChange(of: ideaLink.openClips) { _, open in
            if open { tab = 0; ideaLink.openClips = false }
        }
        // Tapping the home-screen widget opens the Calendar.
        .onOpenURL { url in
            if url.scheme == "clipstudio", url.host() == "calendar" { tab = 1 }
        }
    }
}

/// The big title at the top left of each tab, with an optional button on the right (like +).
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title).font(.largeTitle.bold())
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// The round + button that sits next to a page title.
struct HeaderAddButton: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.title3.weight(.semibold))
            .frame(width: 36, height: 36)
            .background(Theme.accent.opacity(0.16), in: Circle())
            .foregroundStyle(Theme.accent)
            .contentShape(Circle())
    }
}

enum Theme {
    static let accent = Color(red: 0.85, green: 0.64, blue: 0.25)
}
