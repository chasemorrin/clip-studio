import AVFoundation
import CoreGraphics

/// How the source footage sits inside the vertical 1080×1920 frame.
/// The editor preview and the export both use this, so what you see is what you get.
struct Framing: Hashable {
    /// 1 = the whole picture is visible (black bars if the shape differs). Higher = zoomed in and cropped.
    var zoom: Double = 1
    /// Shift from center, in output pixels (positive = right / down).
    var offsetX: Double = 0
    var offsetY: Double = 0

    static let canvas = ClipRenderer.renderSize

    static func fitScale(_ source: CGSize) -> Double {
        Double(min(canvas.width / source.width, canvas.height / source.height))
    }

    /// The zoom that exactly fills the vertical frame with no black bars.
    static func fillZoom(_ source: CGSize) -> Double {
        Double(max(canvas.width / source.width, canvas.height / source.height)) / fitScale(source)
    }

    /// Starting point: vertical footage fills the frame (nothing is cut off); anything else shows the whole picture.
    static func automatic(for source: CGSize) -> Framing {
        let fill = fillZoom(source)
        return fill < 1.12 ? Framing(zoom: fill) : Framing(zoom: 1)
    }

    /// Output pixels per source pixel.
    func scale(for source: CGSize) -> Double { Framing.fitScale(source) * zoom }

    /// Keeps the zoom sensible and stops the picture sliding further than its own edges.
    func clamped(for source: CGSize) -> Framing {
        var f = self
        f.zoom = min(max(1, f.zoom), max(4, Framing.fillZoom(source) * 2))
        let s = f.scale(for: source)
        let maxX = max(0, (Double(source.width) * s - Double(Framing.canvas.width)) / 2)
        let maxY = max(0, (Double(source.height) * s - Double(Framing.canvas.height)) / 2)
        f.offsetX = min(maxX, max(-maxX, f.offsetX))
        f.offsetY = min(maxY, max(-maxY, f.offsetY))
        return f
    }

    /// True when part of the picture is cut off at the edges.
    func crops(_ source: CGSize) -> Bool {
        let s = scale(for: source)
        return Double(source.width) * s > Double(Framing.canvas.width) + 1 || Double(source.height) * s > Double(Framing.canvas.height) + 1
    }

    /// Where the picture lands in the output, in output pixels.
    func placedRect(for source: CGSize) -> CGRect {
        let s = scale(for: source)
        let w = Double(source.width) * s, h = Double(source.height) * s
        return CGRect(x: (Double(Framing.canvas.width) - w) / 2 + offsetX, y: (Double(Framing.canvas.height) - h) / 2 + offsetY, width: w, height: h)
    }

    /// The transform for AVFoundation: rotate upright (preferredTransform), then scale and place.
    func transform(preferred: CGAffineTransform, naturalSize: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let source = CGSize(width: abs(rect.width), height: abs(rect.height))
        let placed = placedRect(for: source)
        let s = scale(for: source)
        return preferred
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: CGFloat(s), y: CGFloat(s)))
            .concatenating(CGAffineTransform(translationX: placed.minX, y: placed.minY))
    }
}
