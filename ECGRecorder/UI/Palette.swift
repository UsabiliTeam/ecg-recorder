import SwiftUI

/// Participant hues. Each participant keeps one for good, everywhere it appears.
enum Palette {
    static let participants: [Color] = [.blue, .orange, .mint, .pink, .purple, .yellow, .teal, .indigo]
    static var participantCount: Int { participants.count }
    /// Condition label hues; chosen per label in Settings.
    static let labels: [Color] = [.blue, .green, .orange, .red, .purple, .pink, .teal, .yellow, .indigo, .brown, .mint, .gray]
    static func label(_ index: Int) -> Color { labels[abs(index) % labels.count] }
}
