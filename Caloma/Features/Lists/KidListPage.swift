import SwiftData
import SwiftUI

/// A list tab in Kid View (and on the Family Board): "Bear Lake Trip · 3".
struct KidListTab: Identifiable, Equatable {
    var id: UUID
    var title: String
    var symbol: String
    /// Things still to do.
    var left: Int
}

/// A kid's part of a list, in Kid View: the list's name and how far along they are, then a
/// tile per thing, like their jobs. Checking things off doesn't earn points, and a tap undoes it.
struct KidListPage: View {
    var list: FamilyList
    var kid: Member
    var items: [FamilyListItem]

    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var checks: [FamilyListCheck]
    @State private var celebrating: UUID?
    @State private var celebration = 0

    private var color: Color { kid.color.color }
    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        let mine = FamilyLists.items(of: list, for: kid.id, in: items)
        let done = mine.filter { FamilyLists.isDone($0, for: kid.id, checks: checks) }.count
        let next = mine.first { !FamilyLists.isDone($0, for: kid.id, checks: checks) }?.id
        VStack(spacing: 14) {
            header(done: done, total: mine.count)
            if done == mine.count && !mine.isEmpty {
                allPacked
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            LazyVGrid(columns: compact ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                ForEach(mine) { item in
                    ListItemTile(
                        item: item,
                        listSymbol: list.symbol,
                        kid: kid,
                        note: note(for: item),
                        isDone: FamilyLists.isDone(item, for: kid.id, checks: checks),
                        isNext: item.id == next,
                        isCelebrating: celebrating == item.id,
                        celebration: celebration,
                        compact: compact
                    ) {
                        toggle(item)
                    }
                    .zIndex(celebrating == item.id ? 1 : 0)
                }
            }
            Text("Checking things off doesn't earn \(PointWords.current().plural). It shows Mom and Dad you're ready.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .animation(.spring(duration: 0.4, bounce: 0.35), value: done == mine.count)
        .sensoryFeedback(.success, trigger: celebration)
    }

    private func header(done: Int, total: Int) -> some View {
        HStack(spacing: compact ? 12 : 20) {
            Image(systemName: list.symbol)
                .font(.system(size: compact ? 24 : 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: compact ? 50 : 56, height: compact ? 50 : 56)
                .background(color, in: .rect(cornerRadius: compact ? 15 : 18))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let when = ListText.kidWhen(list) {
                    Text(when.uppercased())
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(color)
                }
                Text(list.title)
                    .font(.system(size: compact ? 21 : 23, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .layoutPriority(1)
            if !compact {
                ProgressBar(value: total == 0 ? 0 : Double(done) / Double(total), color: done == total ? Brand.done : color)
                    .frame(height: 14)
            } else {
                Spacer(minLength: 4)
            }
            Text("\(done)/\(total)")
                .font(.system(size: compact ? 19 : 23, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.vertical, compact ? 14 : 18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 30))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(list.title), \(done) of \(total) done")
    }

    private var allPacked: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Brand.done, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("All done!")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                Text("Mom and Dad can see you're ready.")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Brand.done.opacity(0.12), in: .rect(cornerRadius: 24))
    }

    /// "Everyone packs one", "Dad asked you to grab it" (a parent gave it to just them and
    /// others), or nothing.
    private func note(for item: FamilyListItem) -> String {
        if FamilyLists.isDone(item, for: kid.id, checks: checks) {
            if !item.everyone, let by = FamilyLists.doneBy(item, checks: checks).first, by != kid.id,
               let person = members.first(where: { $0.id == by }) {
                return "\(person.name) got it"
            }
            return "Done!"
        }
        if item.everyone { return "Everyone needs one" }
        let others = item.assigneeIDs.filter { $0 != kid.id }
        if others.isEmpty { return "Just for you" }
        let names = members.filter { others.contains($0.id) }.map(\.name)
        return names.isEmpty ? "Shared" : "You or " + names.formatted(.list(type: .or))
    }

    private func toggle(_ item: FamilyListItem) {
        let wasDone = FamilyLists.isDone(item, for: kid.id, checks: checks)
        withAnimation(.spring(duration: 0.45, bounce: 0.4)) {
            FamilyLists.toggle(item, for: kid.id, in: context)
            if !wasDone {
                celebrating = item.id
                celebration += 1
            }
        }
        guard !wasDone else { return }
        let stamp = celebration
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            if celebration == stamp { celebrating = nil }
        }
    }
}

/// One thing on a kid's list, looking like their job tiles: an icon (its own, or the list's),
/// the name, who it's for, and a big button. A tap on a done thing undoes it.
private struct ListItemTile: View {
    var item: FamilyListItem
    var listSymbol: String
    var kid: Member
    var note: String
    var isDone: Bool
    var isNext: Bool
    var isCelebrating: Bool
    var celebration: Int
    var compact: Bool
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var color: Color { kid.color.color }
    private var symbol: String { item.symbol.isEmpty ? listSymbol : item.symbol }

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 14) {
                    icon(size: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        title
                        subtitle
                    }
                    Spacer(minLength: 4)
                    button(width: 76, height: 58)
                }
                .padding(14)
            } else {
                VStack(spacing: 12) {
                    icon(size: 92)
                    VStack(spacing: 6) {
                        title.multilineTextAlignment(.center)
                        subtitle
                    }
                    Spacer(minLength: 0)
                    button(width: nil, height: 60)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(minHeight: 250)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 30))
        .overlay {
            RoundedRectangle(cornerRadius: 30)
                .strokeBorder(color, lineWidth: isDone ? 4 : 0)
        }
        .overlay(alignment: .topTrailing) {
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, color)
                    .padding(12)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .overlay {
            if isCelebrating && !reduceMotion {
                ConfettiBurst(colors: confettiColors(color))
                    .id(celebration)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: isDone ? color.opacity(0.25) : .black.opacity(0.05), radius: isDone ? 14 : 8, y: 6)
        .accessibilityElement(children: .combine)
    }

    private func icon(size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(isDone ? .white : color)
            .frame(width: size, height: size)
            .background(isDone ? color : color.opacity(0.14), in: Circle())
            .symbolEffect(.bounce, value: isCelebrating ? celebration : 0)
            .accessibilityHidden(true)
    }

    private var title: some View {
        Text(item.title)
            .font(.system(size: compact ? 20 : 23, weight: .heavy, design: .rounded))
            .strikethrough(isDone)
            .foregroundStyle(isDone ? .secondary : .primary)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    private var subtitle: some View {
        Text(note)
            .font(.system(size: compact ? 15 : 17, weight: .bold, design: .rounded))
            .foregroundStyle(isDone ? Brand.done : .secondary)
            .contentTransition(.opacity)
    }

    private func button(width: CGFloat?, height: CGFloat) -> some View {
        Button(action: action) {
            Group {
                if isDone {
                    Image(systemName: "checkmark")
                } else {
                    Text("Got it!")
                }
            }
            .font(.system(size: compact ? 18 : 22, weight: .heavy, design: .rounded))
            .foregroundStyle(isDone ? color : .white)
            .frame(maxWidth: width == nil ? .infinity : width, minHeight: height)
            .frame(width: width)
            .background(isDone ? AnyShapeStyle(color.opacity(0.13)) : AnyShapeStyle(color), in: Capsule())
            .shadow(color: isDone ? .clear : color.opacity(0.35), radius: 10, y: 6)
            .scaleEffect(isNext && pulse && !reduceMotion ? 1.05 : 1)
        }
        .buttonStyle(KidPressStyle())
        .accessibilityLabel(isDone ? "\(item.title) is done. Tap to undo" : "Check off \(item.title)")
        .onAppear {
            guard isNext else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onChange(of: isNext) { _, next in
            if next {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.default) { pulse = false }
            }
        }
    }
}
