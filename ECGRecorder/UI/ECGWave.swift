import SwiftUI

/// Live ECG from the buffer the engine fills; redraws at 30 Hz and stops while inactive.
/// Packets arrive in bursts, so the trace is shown 0.7 s late and slid continuously between packets.
struct ECGWave: View {
    let buffer: LiveBuffer?
    let active: Bool
    /// Seconds of trace across the width (at most 7, the buffer keeps 8 including the display lag).
    var seconds = 6
    var lineWidth: CGFloat = 1.5
    /// Shows "Waiting for ECG…" on the flat line; off for tiny traces.
    var showsMessage = true
    var color = Theme.ecgLine

    private let rate = LiveBuffer.rate
    private var window: Int { rate * min(seconds, 7) }
    private var lag: Int { rate * 7 / 10 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { ctx in
            // Reading the frame date inside the closure makes SwiftUI redraw the canvas every frame.
            Canvas { g, size in draw(&g, size: size, now: ctx.date.timeIntervalSince1970) }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, now: Double) {
        let (data, age) = active ? (buffer?.snapshot(window + lag, now: now) ?? ([], .infinity)) : ([], .infinity)
        let end = Double(data.count - 1 - lag) + min(age * Double(rate), Double(lag))
        let start = end - Double(window - 1)
        let first = max(0, Int(start.rounded(.up))), last = min(data.count - 1, Int(end.rounded(.down)))
        guard age < 3, last > first else {
            drawFlat(&g, size: size)
            return
        }
        let visible = data[first...last]
        let lo = visible.min() ?? 0, hi = visible.max() ?? 0
        let span = max(hi - lo, 600), mid = (hi + lo) / 2
        var path = Path()
        for i in first...last {
            let x = size.width * CGFloat((Double(i) - start) / Double(window - 1))
            let y = size.height * (0.5 - 0.45 * CGFloat((data[i] - mid) / span * 2))
            if i == first { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        g.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
    }

    private func drawFlat(_ g: inout GraphicsContext, size: CGSize) {
        var flat = Path()
        flat.move(to: CGPoint(x: 0, y: size.height / 2))
        flat.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        g.stroke(flat, with: .color(.secondary.opacity(0.4)), lineWidth: lineWidth)
        if active, showsMessage {
            g.draw(Text("Waiting for ECG…").font(.caption).foregroundStyle(.secondary),
                   at: CGPoint(x: size.width / 2, y: size.height / 2 - 14))
        }
    }
}
