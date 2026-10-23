import SwiftUI

/// One participant over time on a continuous axis. It opens fitted to all their recordings, pinch to
/// stretch or squeeze, drag to move, or jump to a day, week or month. Stacked graphs move together.
struct ParticipantTimelineView: View {
    @Environment(SessionLibrary.self) private var library
    @Environment(Roster.self) private var roster
    let participant: Participant
    @State private var series: [String: [IndexPoint]]?
    @State private var visibleLength: TimeInterval = 86_400
    @State private var position = Date.now
    @State private var pinchStart: TimeInterval?

    private static let minLength: TimeInterval = 120
    private static let maxLength: TimeInterval = 400 * 86_400

    private enum Span: String, CaseIterable, Identifiable {
        case fit = "Fit", day = "Day", week = "Week", month = "Month"
        var id: String { rawValue }
        var length: TimeInterval? {
            switch self {
            case .fit: nil
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            }
        }
    }

    /// First and last moment with data.
    private var dataRange: ClosedRange<Date>? {
        let times = (series ?? [:]).values.flatMap { $0.map(\.t) }
        guard let lo = times.min(), let hi = times.max() else { return nil }
        return Date(timeIntervalSince1970: lo)...Date(timeIntervalSince1970: hi)
    }

    /// The scrollable extent: the data with a little room, and never shorter than what is visible.
    private var domain: ClosedRange<Date> {
        guard let data = dataRange else { return Date.now.addingTimeInterval(-86_400)...Date.now }
        let pad = max(data.upperBound.timeIntervalSince(data.lowerBound) * 0.05, 30)
        let lo = data.lowerBound.addingTimeInterval(-pad)
        return lo...max(data.upperBound.addingTimeInterval(pad), lo.addingTimeInterval(visibleLength))
    }

    var body: some View {
        ScrollView {
            if let series {
                if series.isEmpty {
                    ContentUnavailableView("No recordings", systemImage: "chart.xyaxis.line",
                                           description: Text("\(participant.pseudonym) has no recordings yet."))
                } else {
                    content(series)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(participant.pseudonym)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            series = await library.timeline(for: participant.pseudonym)
            select(.fit)
        }
    }

    private func content(_ series: [String: [IndexPoint]]) -> some View {
        let zoom = MetricChart.Zoom(visibleLength: visibleLength, position: $position)
        return VStack(alignment: .leading, spacing: 20) {
            Picker("Span", selection: Binding(get: { nearestSpan }, set: select)) {
                ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            MetricStack(defaults: Metric.participantDefaults, optional: Metric.participantOptional) { metric in
                MetricChart(title: "\(metric.title) (\(metric.unit))", points: ChartData.points(series, metric: metric),
                            domain: domain, tint: roster.color(for: participant.pseudonym),
                            xValues: .automatic(desiredCount: 4), xLabel: axisLabel, zoom: zoom)
            }
        }
        .padding()
        .gesture(pinch)
    }

    /// Which preset the current zoom is closest to, so the picker follows pinching without fighting it.
    private var nearestSpan: Span {
        guard let fit = fitLength else { return .day }
        return Span.allCases.first { ($0.length ?? fit) == visibleLength } ?? .fit
    }

    private var fitLength: TimeInterval? {
        guard let data = dataRange else { return nil }
        let span = data.upperBound.timeIntervalSince(data.lowerBound)
        return min(max(span * 1.1, Self.minLength), Self.maxLength)
    }

    private func select(_ span: Span) {
        guard let data = dataRange, let fit = fitLength else { return }
        switch span.length {
        case nil:
            visibleLength = fit
            position = data.lowerBound.addingTimeInterval(-fit * 0.05 / 1.1)
        case let length?:
            visibleLength = length
            position = data.upperBound.addingTimeInterval(-length * 0.95)
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchStart ?? visibleLength
                pinchStart = base
                let center = position.addingTimeInterval(visibleLength / 2)
                visibleLength = min(max(base / value.magnification, Self.minLength), Self.maxLength)
                position = center.addingTimeInterval(-visibleLength / 2)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Times when zoomed in to a day or two, dates when zoomed out.
    private func axisLabel(_ date: Date) -> String {
        visibleLength <= 36 * 3600
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.day().month(.abbreviated))
    }
}
