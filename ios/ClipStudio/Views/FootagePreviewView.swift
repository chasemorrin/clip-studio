import AVKit
import SwiftUI

/// After choosing footage: watch it to make sure it's the right video, pick how to find clips, then start.
struct FootagePreviewView: View {
    let url: URL
    let assetID: String?

    @ObservedObject private var store = ProjectStore.shared
    @AppStorage("pickMode") private var modeRaw = PickMode.claude.rawValue
    @State private var player: AVPlayer?
    @State private var duration: Double?
    @State private var start: Footage?
    @State private var manual: Footage?
    @State private var openSaved: OpenSaved?

    private var mode: PickMode { PickMode(rawValue: modeRaw) ?? .claude }
    private var saved: SavedProject? { assetID.flatMap { store.project(forAsset: $0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    if let player {
                        VideoPlayer(player: player)
                    } else {
                        Color.black.overlay(ProgressView().tint(.white))
                    }
                }
                .frame(height: 380)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                if let duration {
                    Text("Length \(timecode(duration))")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }

                if let saved {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You've already found clips in this video.").font(.subheadline.weight(.semibold))
                        Button {
                            player?.pause()
                            openSaved = OpenSaved(project: saved, url: url)
                        } label: {
                            Label("Open its \(saved.clipCount) saved clip\(saved.clipCount == 1 ? "" : "s")", systemImage: "film.stack")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        Text("Or pick a method below to look for clips again.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Find clips with").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Find clips with", selection: $modeRaw) {
                        ForEach(PickMode.allCases) { m in Text(m.label).tag(m.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Text(mode == .manual
                         ? "Use the whole video as is: trim, frame, caption and schedule it yourself."
                         : mode.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    player?.pause()
                    if mode == .manual {
                        manual = Footage(url: url, useClaude: false, assetID: assetID)
                    } else {
                        start = Footage(url: url, useClaude: mode == .claude, assetID: assetID)
                    }
                } label: {
                    Label(mode == .manual ? "Edit this video" : "Find clips",
                          systemImage: mode == .manual ? "scissors" : mode == .claude ? "sparkles" : "waveform")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .navigationTitle("Check your footage")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $start) { f in ProjectView(url: f.url, useClaude: f.useClaude, assetID: f.assetID) }
        .navigationDestination(item: $manual) { f in ManualVideoView(url: f.url, assetID: f.assetID) }
        .navigationDestination(item: $openSaved) { o in ProjectView(saved: o.project, url: o.url) }
        .task {
            if player == nil { player = AVPlayer(url: url) }
            if duration == nil, let d = try? await AVURLAsset(url: url).load(.duration) { duration = d.seconds }
        }
        .onDisappear { player?.pause() }
    }
}
