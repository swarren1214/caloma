import SwiftData
import SwiftUI

// iPhone Duo, Chores tab.
// - Open tall (and every other screen): "Today" puts each kid's ring across the top in three
//   even columns (`DuoTodayRings`); tap a ring to show only that kid's chores.
// - Open wide (inner landscape): "Chore chart" (`DuoChoreChart`), rooms on the leading pane and
//   the chosen room's week, Monday to Saturday, on the trailing pane.

/// Each kid's ring for today, three to a row. Tapping one filters the board to that kid (tap
/// again for everyone).
struct DuoTodayRings: View {
    var family: FamilySnapshot
    @Binding var selection: UUID?

    var body: some View {
        if !family.kids.isEmpty {
            LazyVGrid(columns: HearthEvenColumns.flexible(3, spacing: 10), spacing: 10) {
                ForEach(family.kids) { kid in
                    let selected = selection == kid.id
                    Button {
                        withAnimation(.snappy) { selection = selected ? nil : kid.id }
                    } label: {
                        KidTodayCard(kid: kid, family: family)
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 22)
                                        .strokeBorder(kid.color.color, lineWidth: 2.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(selected ? "Shows everyone's chores" : "Shows only \(kid.name)'s chores")
                }
            }
        }
    }
}

/// The chore chart for the inner display in landscape: rooms on the leading pane, the chosen
/// room's week (Monday to Saturday, six columns so a fold falls between days) on the trailing
/// pane, with one avatar a day for whoever has it. Today's column is outlined. Tap a chore's
/// name to pick it (for Assign in the toolbar); tap a day up to today to check it off or undo it.
struct DuoChoreChart: View {
    /// Every chore, not filtered by room (the chart filters).
    var family: FamilySnapshot
    var rooms: [Room]
    @Binding var roomID: UUID?
    @Binding var selectedChoreID: UUID?
    var completions: [ChoreCompletion]
    var onEdit: (UUID) -> Void

    var body: some View {
        HearthFoldSplit(axes: .horizontal) {
            roomsPane
        } secondary: {
            DuoWeekChart(family: family, room: rooms.first { $0.id == roomID }, roomID: roomID, selectedChoreID: $selectedChoreID, completions: completions, onEdit: onEdit)
        }
        .colorHeader("Chores")
    }

    private var roomsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeaderTitle("Chores", subtitle: "This week by room")
                VStack(spacing: 0) {
                    roomRow(name: "All Rooms", symbol: "house", id: nil)
                    ForEach(rooms) { room in
                        Divider().padding(.leading, 56)
                        roomRow(name: room.name, symbol: room.symbol, id: room.id)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                if rooms.isEmpty {
                    Text("Add rooms in Profile › Rooms to see each room's week.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .refreshesFromICloud()
    }

    private func roomRow(name: String, symbol: String, id: UUID?) -> some View {
        let selected = roomID == id
        let count = choreCount(in: id)
        return Button {
            withAnimation(.snappy) {
                roomID = id
                selectedChoreID = nil
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .frame(width: 30)
                Text(name)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(selected ? Color(.tertiarySystemFill) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(name), \(count) chores")
    }

    /// Chores that come up this week in a room (nil: every room).
    private func choreCount(in id: UUID?) -> Int {
        var seen = Set<UUID>()
        for day in DuoWeek.days() {
            for item in family.items(on: day) where id == nil || item.chore.roomID == id {
                seen.insert(item.chore.id)
            }
        }
        return seen.count
    }
}

/// Monday to Saturday of this week (on a Sunday, the week just ending).
enum DuoWeek {
    static func days(containing date: Date = .now, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: today)
        // Monday 0, Tuesday 1 … Sunday 6.
        let back = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -back, to: today) else { return [] }
        return (0..<6).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }
}

/// The trailing pane: a room's chores down the side and six day columns.
private struct DuoWeekChart: View {
    var family: FamilySnapshot
    var room: Room?
    var roomID: UUID?
    @Binding var selectedChoreID: UUID?
    var completions: [ChoreCompletion]
    var onEdit: (UUID) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @State private var width: CGFloat = 0

    private let rowHeight: CGFloat = 54

    var body: some View {
        let days = DuoWeek.days()
        let perDay = days.map { day in
            family.items(on: day).filter { roomID == nil || $0.chore.roomID == roomID }
        }
        let chores = uniqueChores(perDay.flatMap { $0 })
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room?.name ?? "All Rooms")
                        .font(.title2.bold())
                    if let first = days.first, let last = days.last {
                        Text("\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.subheadline)
                            // White over the color header, a touch softer (as HeaderTitle's subtitle).
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                if chores.isEmpty {
                    EmptyCard(symbol: "checklist", title: "No chores here this week", message: "Add a chore and pick this room for it.")
                } else {
                    chart(days: days, perDay: perDay, chores: chores)
                }
                Text("Tap a chore, then Assign to change who does it. Tap a day to check it off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshesFromICloud()
    }

    private func chart(days: [Date], perDay: [[BoardItem]], chores: [ChoreRecord]) -> some View {
        let titleWidth = max(110, width * 0.32)
        return HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Color.clear.frame(height: rowHeight)
                ForEach(chores, id: \.id) { chore in
                    choreTitle(chore)
                }
            }
            .frame(width: titleWidth)
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = Calendar.current.isDateInToday(day)
                VStack(spacing: 0) {
                    VStack(spacing: 1) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption.weight(.semibold))
                        Text(day.formatted(.dateTime.day()))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(isToday ? Color.primary : Color.secondary)
                    .frame(height: rowHeight)
                    ForEach(chores, id: \.id) { chore in
                        cell(perDay[index].filter { $0.chore.id == chore.id }, day: day)
                            .frame(height: rowHeight)
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(accent, lineWidth: 2)
                            .padding(.vertical, 2)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(isToday ? "Today, \(day.formatted(.dateTime.weekday(.wide)))" : day.formatted(.dateTime.weekday(.wide)))
            }
        }
        .padding(.horizontal, 8)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
    }

    private func choreTitle(_ chore: ChoreRecord) -> some View {
        let selected = selectedChoreID == chore.id
        return Button {
            withAnimation(.snappy) { selectedChoreID = selected ? nil : chore.id }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: chore.symbol)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 22)
                Text(chore.title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
            .background(selected ? Color(.tertiarySystemFill) : Color.clear, in: .rect(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Edit Chore", menuIcon: "pencil") { onEdit(chore.id) }
        }
    }

    /// One avatar for the day: who has it (the first, with +N when there are more), dimmed
    /// while it's still to do, with a check when it's done.
    @ViewBuilder
    private func cell(_ items: [BoardItem], day: Date) -> some View {
        if let first = items.first {
            let target = items.first { $0.status == .open } ?? first
            let member = family.member(target.memberID)
            let canTap = member != nil && Calendar.current.startOfDay(for: day) <= Calendar.current.startOfDay(for: .now)
            Button {
                guard let member else { return }
                withAnimation(.snappy) {
                    ParentChoreTap.toggle(target, for: member.id, completions: completions, in: context)
                }
            } label: {
                avatar(member, status: target.status, extra: items.count - 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canTap)
            .accessibilityLabel(cellLabel(target, member: member))
        } else {
            Color.clear
        }
    }

    private func avatar(_ member: Member?, status: ItemStatus, extra: Int) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let member {
                MemberAvatar(member, size: 30)
                    .opacity(status == .open ? 0.5 : 1)
            } else {
                Image(systemName: "questionmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(Color(.systemGray3), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
            }
            if status != .open {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, status == .pending ? Brand.waiting : Color.green)
                    .offset(x: 4, y: 4)
            } else if extra > 0 {
                Text("+\(extra)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 3)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    .offset(x: 6, y: 4)
            }
        }
    }

    private func cellLabel(_ item: BoardItem, member: Member?) -> String {
        let who = member?.name ?? "Up for grabs"
        switch item.status {
        case .open: return "\(who), to do"
        case .pending: return "\(who), waiting for OK"
        case .approved: return "\(who), done"
        }
    }

    private func uniqueChores(_ items: [BoardItem]) -> [ChoreRecord] {
        var seen = Set<UUID>()
        return items.compactMap { item in
            seen.insert(item.chore.id).inserted ? item.chore : nil
        }
    }
}
