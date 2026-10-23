import SwiftUI

/// Participant hues. Each participant keeps one for good, everywhere it appears.
enum Palette {
    static let participants: [Color] = [.blue, .orange, .mint, .pink, .purple, .yellow, .teal, .indigo]
    static var participantCount: Int { participants.count }
}
