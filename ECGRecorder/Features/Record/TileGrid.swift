import SwiftUI

/// Layout adapts to the number of participants and never scrolls.
/// One = hero tile, two or three = stacked tiles, four to six = two-column grid.
enum TileStyle {
    case full, medium, compact

    init(count: Int) {
        switch count {
        case ...1: self = .full
        case 2...3: self = .medium
        default: self = .compact
        }
    }
}

struct TileGrid: View {
    let slots: [Slot]

    var body: some View {
        let style = TileStyle(count: slots.count)
        switch style {
        case .full, .medium:
            VStack(spacing: Theme.gap) { ForEach(slots) { LiveTile(slot: $0, style: style) } }
        case .compact:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.gap), GridItem(.flexible())], spacing: Theme.gap) {
                ForEach(slots) { LiveTile(slot: $0, style: style) }
            }
        }
    }
}
