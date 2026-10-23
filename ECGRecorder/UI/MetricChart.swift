import SwiftUI
import Charts

/// Line chart for the recording detail and participant timeline. One line per series.
struct MetricChart: View {
    let title: String
    let points: [ChartPoint]
    let domain: ClosedRange<Date>
    /// Series name to colour; when empty every series uses `tint`.
    var colors: [String: Color] = [:]
    var tint: Color = .accentColor
    var xValues: AxisMarkValues = .automatic
    var xLabel: (Date) -> String = { $0.formatted(.dateTime.hour().minute()) }
    var height: CGFloat = 220
    /// When set, the time axis scrolls and zooms: seconds visible at once and the left edge (shared by stacked charts).
    var zoom: Zoom?
    /// Events marked during the recording, drawn as labelled vertical lines.
    var markers: [EventMarker] = []

    struct Zoom {
        var visibleLength: TimeInterval
        var position: Binding<Date>
    }

    /// The tapped point, if any; shown as a tooltip until the user taps elsewhere (or the same point again).
    @State private var selected: ChartPoint?

    private var seriesNames: [String] { Set(points.map(\.series)).sorted() }
    /// Lines with only a handful of points would look like a dive, so those also get dots.
    private var showsDots: Bool { points.count < 40 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            chart.frame(height: height)
            if colors.count > 1 { legend }
        }
        .onChange(of: title) { _, _ in selected = nil }
        .onChange(of: domain) { _, _ in selected = nil }
    }

    @ViewBuilder
    private var chart: some View {
        let base = Chart {
            markerMarks
            ForEach(points) { p in
                LineMark(x: .value("Time", p.time), y: .value(title, p.value), series: .value("Series", p.series))
                    .foregroundStyle(color(for: p.series))
                if showsDots {
                    PointMark(x: .value("Time", p.time), y: .value(title, p.value))
                        .foregroundStyle(color(for: p.series)).symbolSize(20)
                }
            }
            if let selected {
                RuleMark(x: .value("Time", selected.time))
                    .foregroundStyle(.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 8, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(for: selected)
                    }
                PointMark(x: .value("Time", selected.time), y: .value(title, selected.value))
                    .foregroundStyle(color(for: selected.series))
                    .symbolSize(110)
            }
        }
        base
            .zoomable(zoom)
            .chartXScale(domain: domain)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: xValues) { value in
                    AxisGridLine()
                    AxisValueLabel { if let date = value.as(Date.self) { Text(xLabel(date)) } }
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)))
                }
            }
            .chartOverlay { proxy in tapOverlay(proxy) }
    }

    @ChartContentBuilder
    private var markerMarks: some ChartContent {
        ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
            RuleMark(x: .value("Time", Date(timeIntervalSince1970: marker.t)))
                .foregroundStyle(.orange.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    Text(marker.name).font(.caption2).foregroundStyle(.secondary)
                }
        }
    }

    /// A tap anywhere on the chart selects the nearest point, in screen space, to the finger - forgiving of
    /// imprecise touches, and works alongside the existing scroll/pinch zoom since a tap claims no drag.
    private func tapOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let origin = geometry[plotFrame].origin
                            let location = CGPoint(x: value.location.x - origin.x, y: value.location.y - origin.y)
                            let nearest = nearestPoint(to: location, proxy: proxy)
                            selected = (selected?.id == nearest?.id) ? nil : nearest
                        }
                )
        }
    }

    private func nearestPoint(to location: CGPoint, proxy: ChartProxy) -> ChartPoint? {
        points.min { distanceSquared($0, to: location, proxy: proxy) < distanceSquared($1, to: location, proxy: proxy) }
    }

    private func distanceSquared(_ point: ChartPoint, to location: CGPoint, proxy: ChartProxy) -> CGFloat {
        guard let x = proxy.position(forX: point.time), let y = proxy.position(forY: point.value) else { return .infinity }
        return (x - location.x) * (x - location.x) + (y - location.y) * (y - location.y)
    }

    private func tooltip(for point: ChartPoint) -> some View {
        VStack(spacing: 2) {
            if colors.count > 1 {
                Text(point.series).font(.caption2.weight(.semibold)).foregroundStyle(color(for: point.series))
            }
            Text(xLabel(point.time)).font(.caption2).foregroundStyle(.secondary)
            Text(point.value.formatted(.number.precision(.fractionLength(0)))).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(colors.keys.sorted(), id: \.self) { name in
                HStack(spacing: 6) {
                    ParticipantDot(color: colors[name] ?? tint, size: 8)
                    Text(name).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func color(for series: String) -> Color { colors[series] ?? tint }
}

private extension View {
    @ViewBuilder
    func zoomable(_ zoom: MetricChart.Zoom?) -> some View {
        if let zoom {
            chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: zoom.visibleLength)
                .chartScrollPosition(x: zoom.position)
        } else {
            self
        }
    }
}
