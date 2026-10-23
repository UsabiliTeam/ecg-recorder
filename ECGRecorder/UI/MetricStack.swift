import SwiftUI

/// Graphs stacked in a fixed order, with a menu to add more. Added graphs can be removed again.
struct MetricStack<Chart: View>: View {
    let defaults: [Metric]
    let optional: [Metric]
    @ViewBuilder let chart: (Metric) -> Chart
    @State private var added: [Metric] = []

    private var remaining: [Metric] { optional.filter { !added.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(defaults) { chart($0) }
            ForEach(added) { metric in
                chart(metric).contextMenu {
                    Button("Remove graph", systemImage: "minus.circle", role: .destructive) { added.removeAll { $0 == metric } }
                }
            }
            if !remaining.isEmpty { addMenu }
        }
        .animation(.default, value: added)
    }

    private var addMenu: some View {
        Menu {
            ForEach(remaining) { metric in Button(metric.title) { added.append(metric) } }
        } label: {
            Label("Add graph", systemImage: "plus.circle.fill").frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }
}
