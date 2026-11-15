import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile = Config.profile
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $profile)
                        .frame(minHeight: 140)
                } header: {
                    Text("Your music, in your words")
                } footer: {
                    Text("Claude reads this every time it picks clips or writes captions. Name the artists, styles and moments you want more of.")
                }
                Section {
                    Button("Reset to the original text") { profile = Config.defaultProfile }
                }

                Section("Claude") {
                    LabeledContent("Requests today", value: session.claudeDailyLimit > 0 ? "\(session.claudeUsedToday) of \(session.claudeDailyLimit)" : "–")
                }

                Section("Instagram") {
                    LabeledContent("Account", value: session.instagramUsername.map { "@\($0)" } ?? "Not connected yet")
                }

                Section("Server") {
                    LabeledContent("Address", value: Config.serverURL.host() ?? "")
                }

                Section {
                    Button("Sign out") { session.signOut(); dismiss() }
                    Button("Delete account and data", role: .destructive) { confirmDelete = true }
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Config.profile = profile; dismiss() }
                }
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account and data", role: .destructive) {
                    Task {
                        do { try await session.deleteAccount(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } message: {
                Text("This removes your planner, scheduled posts, uploaded clips and Instagram connection from the server. Videos on your phone aren't touched.")
            }
            .task { await session.refreshProfile() }
            .onDisappear { Config.profile = profile }
        }
    }
}
