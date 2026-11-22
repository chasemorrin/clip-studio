import AVKit
import SwiftUI

/// The chosen video, playable right on the Clips tab, so you can check it's the right one before scanning it.
struct FootagePreview: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var duration: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Color.black.overlay(ProgressView().tint(.white))
                }
            }
            .frame(height: 320)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            if let duration {
                Text("Length \(timecode(duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            player = AVPlayer(url: url)
            duration = (try? await AVURLAsset(url: url).load(.duration))?.seconds
        }
        .onDisappear { player?.pause() }
    }
}
