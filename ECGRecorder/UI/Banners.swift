import SwiftUI

extension Binding where Value == Bool {
    /// True while the optional has a value; setting false clears it. Drives alerts and dialogs.
    init<T>(isPresent item: Binding<T?>) {
        self.init(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

struct StorageWarning: View {
    var body: some View {
        Label("Storage is low. Recordings may fail. Delete old recordings.", systemImage: "externaldrive.badge.exclamationmark")
            .font(.footnote).foregroundStyle(.orange)
    }
}

/// A problem shown at the top of the screen, with its fix as one button.
struct ProblemBanner: View {
    let problem: Problem
    var onFix: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: problem.severity == .blocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(problem.severity == .blocking ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title).font(.subheadline.weight(.semibold))
                Text(problem.hint).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if problem.fix == .openSettings, let onFix {
                Button("Settings", action: onFix).font(.subheadline.weight(.semibold))
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}
