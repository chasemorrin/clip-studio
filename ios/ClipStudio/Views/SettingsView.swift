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
    @State private var instagramError: String?
    @State private var showTokenSheet = false
    @State private var connector = InstagramConnector()
    @State private var youtubeConnecting = false
    @State private var youtubeError: String?
    @State private var confirmYouTubeDisconnect = false
    @AppStorage("youtubeByDefault") private var youtubeByDefault = true
    @AppStorage("instagramByDefault") private var instagramByDefault = true
    @State private var storage: StorageUsage.Report?
    @State private var clearing = false

    // Calendar weekday numbers in Monday-first order (1 = Sunday).
    private let weekdays = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Used on this iPhone") {
                        if let storage { Text(StorageUsage.format(storage.total)).font(.headline) } else { ProgressView() }
                    }
                    if let storage {
                        LabeledContent("Saved footage", value: StorageUsage.format(storage.saved))
                        LabeledContent("Temporary video files", value: StorageUsage.format(storage.temporary))
                        LabeledContent("App data", value: StorageUsage.format(storage.other))
                        if storage.temporary > 20_000_000 {
                            Button {
                                Task {
                                    clearing = true
                                    await Task.detached { StorageUsage.clearTemporary() }.value
                                    await measureStorage()
                                    clearing = false
                                }
                            } label: {
                                HStack {
                                    Text("Clear temporary video files")
                                    if clearing { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(clearing)
                        }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Temporary files are copies of videos picked from Photos and exported clips. Clearing them is safe; saved footage reopens from Photos.")
                }

                Section {
                    if let name = session.instagramUsername {
                        LabeledContent("Connected", value: "@\(name)")
                        Toggle("Automatically post clips to Instagram", isOn: $instagramByDefault)
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
                        Button("Connect with an access token…") { showTokenSheet = true }
                    }
                } header: {
                    Text("Instagram")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let instagramError {
                            Text(instagramError).foregroundStyle(.red)
                        }
                        Text("Needed for automatic posting. Your account must be a Creator or Business account. The switches set where new posts go; you can still change it on each post.")
                    }
                }

                Section {
                    if let channel = session.youtubeChannel {
                        LabeledContent("Connected", value: session.youtubeHandle ?? channel)
                        Toggle("Automatically post clips to YouTube", isOn: $youtubeByDefault)
                            .tint(.red)
                        Button("Disconnect YouTube", role: .destructive) { confirmYouTubeDisconnect = true }
                    } else {
                        Button {
                            Task { await connectYouTube() }
                        } label: {
                            HStack {
                                Label("Connect YouTube", systemImage: "play.rectangle")
                                if youtubeConnecting { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(youtubeConnecting)
                    }
                } header: {
                    Text("YouTube Shorts")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let youtubeError {
                            Text(youtubeError).foregroundStyle(.red)
                        }
                        if !session.youtubeAvailable && session.youtubeChannel == nil && youtubeError == nil {
                            Text("Add the Google client ID and secret to the server first (wrangler secret put GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET).")
                        }
                        Text("Vertical clips up to 3 minutes post as Shorts. Until Google approves Clip Studio, YouTube keeps uploads private: make each one public in the YouTube app.")
                    }
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

                DefaultHashtagsSection()

                FriendHandlesSection()

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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .sheet(isPresented: $showTokenSheet) { TokenConnectSheet() }
            .task { await session.refreshProfile() }
            .task { await measureStorage() }
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
            .confirmationDialog("Disconnect YouTube?", isPresented: $confirmYouTubeDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    Task {
                        do {
                            try await APIClient.shared.request("POST", "v1/youtube/disconnect")
                            await session.refreshProfile()
                        } catch { youtubeError = error.localizedDescription }
                    }
                }
            } message: {
                Text("Clip Studio's access to your channel is revoked with Google. Scheduled posts stay on your calendar but won't go to YouTube until you connect again.")
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account and data", role: .destructive) {
                    Task {
                        do { try await session.deleteAccount() } catch { self.error = error.localizedDescription }
                    }
                }
            } message: {
                Text("This removes your calendar, scheduled posts, uploaded clips and Instagram and YouTube connections from the server. Videos on your phone aren't touched.")
            }
        }
    }

    private func connectInstagram() async {
        connecting = true
        instagramError = nil
        defer { connecting = false }
        do {
            _ = try await connector.connect()
            await session.refreshProfile()
        } catch let e as APIError where e.code == "cancelled" {
            // The person closed the login sheet; nothing to report.
        } catch let e as APIError where e.code == "not_configured" {
            instagramError = "Instagram isn't set up on the server yet. Create the Meta app and add its ID and secret to the server (README: Connect Instagram), then try again."
        } catch {
            instagramError = error.localizedDescription
        }
    }

    private func measureStorage() async {
        storage = await Task.detached { StorageUsage.measure() }.value
    }

    private func connectYouTube() async {
        youtubeConnecting = true
        youtubeError = nil
        defer { youtubeConnecting = false }
        do {
            _ = try await connector.connectYouTube()
        } catch let e as APIError where e.code == "cancelled" {
            // Closed the login sheet.
        } catch let e as APIError where e.code == "not_configured" {
            youtubeError = "YouTube isn't set up on the server yet. Add the Google client ID and secret (wrangler secret put GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET), then try again."
        } catch {
            youtubeError = error.localizedDescription
        }
        // Also picks up whether the server has the Google keys now.
        await session.refreshProfile()
    }

    static func timeFromMinutes(_ m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
}

/// For your own account: paste an access token generated in Meta's dashboard.
struct TokenConnectSheet: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste the access token", text: $token, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste from clipboard") { token = UIPasteboard.general.string ?? "" }
                } footer: {
                    Text("In Meta's dashboard: your app → Instagram use case → API setup → Generate access tokens → Add account. Copy the token it shows and paste it here. It's sent only to your Clip Studio server.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Connect with a token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "Connecting…" : "Connect") {
                        Task {
                            working = true
                            error = nil
                            defer { working = false }
                            do {
                                try await APIClient.shared.request("POST", "v1/instagram/token", json: ["token": token])
                                await session.refreshProfile()
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(working || token.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
                }
            }
        }
    }
}
