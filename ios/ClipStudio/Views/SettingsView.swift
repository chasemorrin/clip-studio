import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @State private var profile = Config.profile
    @State private var days = PostingSchedule.days
    @State private var postTime = SettingsView.timeFromMinutes(PostingSchedule.minutes)
    @State private var connecting = false
    @State private var confirmDelete = false
    @State private var confirmDisconnect = false
    @State private var error: String?
    @State private var connector = InstagramConnector()

    // Calendar weekday numbers in Monday-first order (1 = Sunday).
    private let weekdays = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let name = session.instagramUsername {
                        LabeledContent("Connected", value: "@\(name)")
                        Button("Disconnect Instagram", role: .destructive) { confirmDisconnect = true }
                    } else {
                        Button {
                            Task { await connectInstagram() }
                        } label: {
                            HStack {
                                Label("Connect Instagram", systemImage: "link")
                                if connecting { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(connecting)
                    }
                } header: {
                    Text("Instagram")
                } footer: {
                    Text("Needed for automatic posting. Your account must be a Creator or Business account.")
                }

                Section {
                    HStack(spacing: 6) {
                        ForEach(weekdays, id: \.self) { day in
                            let on = days.contains(day)
                            let letter = Calendar.current.veryShortWeekdaySymbols[day - 1]
                            Button {
                                if on { days.remove(day) } else { days.insert(day) }
                                PostingSchedule.days = days
                            } label: {
                                Text(letter)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .foregroundStyle(on ? Color.black : Color.primary)
                                    .background(on ? Theme.accent : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    DatePicker("Post at", selection: $postTime, displayedComponents: .hourAndMinute)
                        .onChange(of: postTime) { _, t in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: t)
                            PostingSchedule.minutes = (c.hour ?? 18) * 60 + (c.minute ?? 30)
                        }
                } header: {
                    Text("Posting schedule")
                } footer: {
                    Text(days.isEmpty
                         ? "Pick at least one day. New clips go to your next open posting day."
                         : "New clips go to your next open posting day at this time. You can change any single post in Calendar.")
                }

                Section {
                    TextEditor(text: $profile)
                        .frame(minHeight: 140)
                        .onChange(of: profile) { _, v in Config.profile = v }
                    Button("Reset to the original text") { profile = Config.defaultProfile }
                } header: {
                    Text("Your music, in your words")
                } footer: {
                    Text("Claude reads this every time it picks clips or writes captions.")
                }

                Section("Claude") {
                    LabeledContent("Requests today", value: session.claudeDailyLimit > 0 ? "\(session.claudeUsedToday) of \(session.claudeDailyLimit)" : "–")
                }

                Section {
                    LabeledContent("Server", value: Config.serverURL.host() ?? "")
                    Button("Sign out") { session.signOut() }
                    Button("Delete account and data", role: .destructive) { confirmDelete = true }
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Settings")
            .task { await session.refreshProfile() }
            .confirmationDialog("Disconnect Instagram?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    Task {
                        do {
                            try await APIClient.shared.request("POST", "v1/instagram/disconnect")
                            await session.refreshProfile()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            } message: {
                Text("Scheduled posts stay on your calendar but won't post until you connect again.")
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account and data", role: .destructive) {
                    Task {
                        do { try await session.deleteAccount() } catch { self.error = error.localizedDescription }
                    }
                }
            } message: {
                Text("This removes your calendar, scheduled posts, uploaded clips and Instagram connection from the server. Videos on your phone aren't touched.")
            }
        }
    }

    private func connectInstagram() async {
        connecting = true
        error = nil
        defer { connecting = false }
        do {
            _ = try await connector.connect()
            await session.refreshProfile()
        } catch let e as APIError where e.code == "cancelled" {
            // The person closed the login sheet; nothing to report.
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func timeFromMinutes(_ m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
}
