import SwiftUI
import UIKit

// The pieces every Caloma screen is built from, matching the Tend designs: grouped-gray
// screens, white 22 pt cards, tinted icon tiles, kid avatars with progress rings, star counts,
// and capsule chips for picking kids.

/// A white card with the designs' 22 pt corners.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

/// Rows inside a white card, with hairlines between them.
struct CardList<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    var items: Data
    var inset: CGFloat = 62
    @ViewBuilder var row: (Data.Element) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    Divider().padding(.leading, inset)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

/// "Kids Today", "Home Care": the 22 pt section titles, with an optional control on the right.
struct SectionTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
                .font(.subheadline)
        }
        .padding(.horizontal, 4)
    }
}

/// A tab's screen: a large title, then cards in a readable column (wider on iPad).
struct CalomaScreen<Content: View>: View {
    static var readableWidth: CGFloat { 860 }

    var title: String
    var maxWidth: CGFloat = CalomaScreen.readableWidth
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// A rounded square with an SF Symbol on a pale wash of its color.
struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 34
    var filled = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(filled ? Color.white : color)
            .frame(width: size, height: size)
            .background(filled ? color : color.opacity(0.15), in: .rect(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A person's circle: their photo, or their initial on a gradient of their color.
struct MemberAvatar: View {
    var name: String
    var color: Color
    var photo: Data?
    var size: CGFloat = 36

    init(name: String, color: Color, photo: Data? = nil, size: CGFloat = 36) {
        self.name = name
        self.color = color
        self.photo = photo
        self.size = size
    }

    init(_ member: Member, size: CGFloat = 36) {
        self.init(name: member.name, color: member.color.color, photo: member.photoData, size: size)
    }

    var body: some View {
        Group {
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [color, color.mix(with: .black, by: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// A ring that fills as things get done.
struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6, bounce: 0.35), value: progress)
        }
        .accessibilityHidden(true)
    }
}

/// A star (or the family's own symbol) and a number.
struct PointsLabel: View {
    var points: Int
    var font: Font = .subheadline.weight(.semibold)
    var color: Color = Brand.star

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: PointWords.current().symbol)
                .foregroundStyle(color)
                .font(font)
                .imageScale(.small)
            Text(points.formatted())
                .font(font)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PointWords.current().count(points))
    }
}

/// A capsule for picking a kid (or a filter): their dot and name, filled with their color
/// when selected.
struct Chip: View {
    var title: String
    var color: Color
    var isOn: Bool
    var showsDot = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showsDot {
                    Circle()
                        .fill(isOn ? Color.white : color)
                        .frame(width: 8, height: 8)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? AnyShapeStyle(color) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A small colored label: "Waiting for OK", "Photo", "Experience".
struct TagLabel: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .rect(cornerRadius: 6))
    }
}

/// The round check on a chore row: empty, orange while waiting for an OK, filled when done.
struct ChoreCheck: View {
    var status: ItemStatus
    var color: Color
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color(.systemGray3), lineWidth: 2)
                .opacity(status == .open ? 1 : 0)
            Circle()
                .fill(status == .pending ? Brand.waiting : color)
                .opacity(status == .open ? 0 : 1)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(.white)
                .opacity(status == .open ? 0 : 1)
                .scaleEffect(status == .open ? 0.4 : 1)
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.35, bounce: 0.5), value: status)
    }
}

/// A grid of SF Symbols to pick from.
struct SymbolGrid: View {
    var symbols: [String]
    @Binding var selection: String
    var color: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
            ForEach(symbols, id: \.self) { symbol in
                let on = symbol == selection
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .background(on ? AnyShapeStyle(color) : AnyShapeStyle(Color(.tertiarySystemFill)), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The symbols offered for chores, rewards and home care.
enum SymbolSets {
    static let chores = [
        "bed.double", "mouth", "teddybear", "book", "fork.knife", "dishwasher", "tshirt", "trash",
        "pawprint", "leaf", "car", "basket", "sink", "toilet", "bathtub", "washer",
        "music.note", "pencil", "backpack", "shoeprints.fill", "sparkles", "bubbles.and.sparkles", "sun.max", "checkmark.circle",
    ]

    static let rewards = [
        "tv", "gamecontroller", "fork.knife", "moon.stars", "film", "birthday.cake", "bicycle", "cup.and.saucer",
        "banknote", "gift", "music.note", "book.closed", "calendar", "checkmark.circle", "star", "flag.checkered",
        "figure.play", "tent", "popcorn", "party.popper",
    ]

    static let homeCare = [
        "fan", "light.beacon.max", "drop", "dryer", "washer", "refrigerator", "flame", "heater.vertical",
        "house", "leaf", "spigot", "lightbulb", "bolt", "paintbrush", "hammer", "wrench.and.screwdriver",
        "car", "snowflake", "sun.max", "trash",
    ]
}

/// An empty state: a symbol, a line, and an optional button.
struct EmptyCard: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        Card(padding: 24) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

extension View {
    /// The family's toolbar button to Family settings, on every tab.
    func familyToolbarButton(_ show: Binding<Bool>) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    show.wrappedValue = true
                } label: {
                    Image(systemName: "person.2.fill")
                }
                .accessibilityLabel("Family")
            }
        }
    }
}
