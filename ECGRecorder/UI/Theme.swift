import SwiftUI

/// Design tokens. Screens use these instead of literal numbers so the look changes in one place.
enum Theme {
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let gap: CGFloat = 12
    static let screenPadding: CGFloat = 16
    static let buttonHeight: CGFloat = 56
    static let ecgLine = Color(red: 0.94, green: 0.32, blue: 0.31)
    /// Simulated devices draw in blue so they are never mistaken for real data.
    static let simulatedEcgLine = Color.blue
    static func ecg(simulated: Bool) -> Color { simulated ? simulatedEcgLine : ecgLine }
}

extension Roster {
    /// Stable colour for a pseudonym. Deleted participants fall back to a hash so old sessions stay coloured.
    func color(for pseudonym: String) -> Color {
        let index = participant(named: pseudonym)?.colorIndex ?? Self.stableHash(pseudonym)
        return Palette.participants[index % Palette.participantCount]
    }

    /// FNV-1a; Swift's own hashing changes between launches.
    private static func stableHash(_ text: String) -> Int {
        Int(text.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } & 0x7fffffff)
    }
}

extension LinkState {
    var color: Color {
        switch self {
        case .streaming: .green
        case .connected, .connecting: .yellow
        case .noData: .orange
        case .disconnected: .red
        }
    }
}

extension HRZone.Level {
    var color: Color {
        switch self {
        case .easy: .green
        case .moderate: .yellow
        case .hard: .red
        }
    }
}

extension View {
    /// The one card look used across the app.
    func card() -> some View {
        padding(Theme.cardPadding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Full-width capsule action; red while recording.
struct BigButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Theme.buttonHeight)
            .background(tint, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small coloured dot naming a participant.
struct ParticipantDot: View {
    let color: Color
    var size: CGFloat = 10

    var body: some View { Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true) }
}
