import AVFoundation
import SwiftUI
import UIKit

/// Shows the video through an AVPlayerLayer (keeps HDR and orientation right).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

/// The vertical frame exactly as it will be exported: same crop, same text size and position.
/// Pinch to zoom, drag to move, tap to pause or play.
struct FramedPreview: View {
    let player: AVPlayer
    let source: CGSize
    @Binding var framing: Framing
    let text: String
    let showText: Bool
    var onTap: () -> Void = {}

    @State private var pinchBase: Framing?
    @State private var dragBase: Framing?

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / Framing.canvas.width   // screen points per output pixel
            let placed = framing.placedRect(for: source)
            ZStack {
                Color.black
                PlayerLayerView(player: player)
                    .frame(width: placed.width * k, height: placed.height * k)
                    .position(x: placed.midX * k, y: placed.midY * k)
                    .allowsHitTesting(false)
                // The same text image the export uses, scaled down.
                if showText, let image = ClipRenderer.textImage(text) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: image.size.width * k, height: image.size.height * k)
                        .position(x: Framing.canvas.width / 2 * k,
                                  y: (ClipRenderer.textTop - ClipRenderer.textPad + image.size.height / 2) * k)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnifyGesture()
                        .onChanged { g in
                            let base = pinchBase ?? framing
                            if pinchBase == nil { pinchBase = framing }
                            var f = base
                            f.zoom = base.zoom * Double(g.magnification)
                            framing = f.clamped(for: source)
                        }
                        .onEnded { _ in pinchBase = nil },
                    DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            let base = dragBase ?? framing
                            if dragBase == nil { dragBase = framing }
                            var f = base
                            f.offsetX = base.offsetX + Double(g.translation.width / k)
                            f.offsetY = base.offsetY + Double(g.translation.height / k)
                            framing = f.clamped(for: source)
                        }
                        .onEnded { _ in dragBase = nil }
                )
            )
            .onTapGesture(perform: onTap)
            .animation(.easeInOut(duration: 0.25), value: showText)
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }
}
