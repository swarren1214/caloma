import SwiftData
import SwiftUI

/// The parent's chore board. iPhone: a card per kid. iPad: a column per kid, with Needs Your OK
/// alongside.
struct ChoresView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accent) private var accent
    /// iPhone Duo: inner landscape shows the chore chart; partly folded keeps the board and
    /// Needs Your OK on their own pages.
    @Environment(\.hearthDuoPose) private var pose
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query private var points: [PointEntry]
    @Query private var redemptions: [Redemption]

    @State private var range: BoardRange = .today
    @State private var kidFilter: UUID?
    @State private var roomFilter: UUID?
    @Query(filter: #Predicate<Room> { !$0.isArchived }, sort: \Room.sortOrder) private var rooms: [Room]
    @State private var editing: Chore?
    /// The chore picked on the chore chart (iPhone Duo, inner landscape), for Assign.
    @State private var chartChoreID: UUID?

    enum BoardRange: String, CaseIterable, Identifiable {
        case today = "Today", week = "This Week"
        var id: String { rawValue }
    }

    /// Every chore, for the chore chart (it filters by room itself).
    private var everyChore: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: points, redemptions: redemptions)
    }

    /// With a room picked, the board is built from that room's chores only.
    private var family: FamilySnapshot {
        let shown = roomFilter.map { room in chores.filter { $0.roomID == room } } ?? chores
        return FamilySnapshot(members: members, chores: shown, completions: completions, points: points, redemptions: redemptions)
    }

    private var roomMenu: some View {
        Menu {
            Picker("Room", selection: $roomFilter) {
                Label { Text("All Rooms") } icon: { Image.menuIcon("house") }.tag(UUID?.none)
                ForEach(rooms) { room in
                    Label { Text(room.name) } icon: { Image.menuIcon(room.symbol) }.tag(UUID?.some(room.id))
                }
            }
        } label: {
            let room = rooms.first { $0.id == roomFilter }
            Label(room?.name ?? "All Rooms", systemImage: room?.symbol ?? "door.left.hand.open")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .foregroundStyle(room == nil ? Color.primary : Color.white)
                .background(room == nil ? AnyShapeStyle(Color(.secondarySystemGroupedBackground)) : AnyShapeStyle(accent), in: Capsule())
        }
        // The picker's checkmarks are the text color, not the app's color.
        .tint(.primary)
        .accessibilityLabel("Room filter")
    }

    var body: some View {
        let family = family
        Group {
            if pose == .openWide {
                // iPhone Duo, open in landscape: rooms beside the chosen room's week.
                DuoChoreChart(family: everyChore, rooms: rooms, roomID: $roomFilter, selectedChoreID: $chartChoreID, completions: completions, onEdit: edit)
            } else if sizeClass == .regular && range == .today {
                wideBoard(family)
                    .refreshesFromICloud()
            } else {
                CalomaScreen(title: "Chores") {
                    controls(family)
                    // Every kid's ring across the top (iPhone Duo "Today"); tap one to see only theirs.
                    if range == .today && sizeClass == .compact {
                        DuoTodayRings(family: family, selection: $kidFilter)
                    }
                    if family.choreDoers.isEmpty {
                        EmptyCard(symbol: "person.badge.plus", title: "No one has chores yet", message: "Add kids in Household, then give out chores.")
                    } else if range == .today {
                        todayCards(family)
                    } else {
                        WeekBoard(family: family, kidFilter: kidFilter) { edit($0) }
                    }
                }
            }
        }
        .navigationTitle("Chores")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Group {
                    KidViewButton()
                    Button {
                        router.sheet = .approvals
                    } label: {
                        Label("Needs Your OK", systemImage: "checkmark.shield")
                    }
                    .badge(family.needsOKCount)
                    NavigationLink {
                        RotationsView()
                    } label: {
                        Label("Rotations", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        router.sheet = .newChore
                    } label: {
                        Label("New Chore", systemImage: "plus")
                    }
                    // The chore chart's Assign: who does the picked chore is set in its editor.
                    if pose == .openWide {
                        Button {
                            if let id = chartChoreID { edit(id) }
                        } label: {
                            Label("Assign", systemImage: "person.crop.circle.badge.plus")
                        }
                        .disabled(chartChoreID == nil)
                    }
                }
                // White over the color header.
                .tint(.white)
                HearthProfileButton()
            }
        }
        .sheet(item: $editing) { chore in
            ChoreEditor(chore: chore)
        }
    }

    private func edit(_ choreID: UUID) {
        editing = chores.first { $0.id == choreID }
    }

    @ViewBuilder
    private func controls(_ family: FamilySnapshot) -> some View {
        HStack(spacing: 10) {
            Picker("Range", selection: $range) {
                ForEach(BoardRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if !rooms.isEmpty {
                roomMenu
            }
        }

        if family.choreDoers.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Chip(title: "Everyone", color: accent, isOn: kidFilter == nil, showsDot: false) { kidFilter = nil }
                    ForEach(family.choreDoers) { kid in
                        Chip(title: kid.name, color: kid.color.color, isOn: kidFilter == kid.id) {
                            kidFilter = kidFilter == kid.id ? nil : kid.id
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -16)
        }
    }

    // MARK: iPhone

    @ViewBuilder
    private func todayCards(_ family: FamilySnapshot) -> some View {
        let kids = family.choreDoers.filter { kidFilter == nil || $0.id == kidFilter }
        ForEach(kids) { kid in
            let items = family.items(for: kid).filter { !$0.chore.upForGrabs || $0.memberID == kid.id }
            KidChoreSection(kid: kid, items: items, family: family, onEdit: edit, onToggle: toggle)
        }
        let grabs = family.items().filter { $0.chore.upForGrabs && $0.memberID == nil }
        if !grabs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Up for Grabs") {
                    Text("Any kid can claim").foregroundStyle(.secondary)
                }
                CardList(items: grabs) { item in
                    UpForGrabsRow(item: item, family: family, onEdit: edit) { kid in
                        Family.markDone(item, by: kid.id, byParent: true, in: context)
                    }
                }
            }
        }
    }

    /// A parent's tap: open → done (approved), waiting → approved, done → undone.
    private func toggle(_ item: BoardItem, for kid: Member) {
        withAnimation(.snappy) {
            switch item.status {
            case .open:
                Family.markDone(item, by: kid.id, byParent: true, in: context)
            case .pending:
                if let completion = completions.first(where: { $0.id == item.completionID }) {
                    Family.approve(completion, in: context)
                }
            case .approved:
                if let completion = completions.first(where: { $0.id == item.completionID }) {
                    Family.undo(completion, in: context)
                }
            }
        }
    }

    // MARK: iPad

    @ViewBuilder
    private func wideBoard(_ family: FamilySnapshot) -> some View {
        if pose.isFolded {
            // Partly folded: the board and Needs Your OK each get a page, nothing in the fold.
            HearthFoldSplit {
                boardColumns(family)
            } secondary: {
                ApprovalsPanel()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.large)
        } else {
            HStack(alignment: .top, spacing: 16) {
                boardColumns(family)
                ApprovalsPanel()
                    .frame(width: 320)
                    .padding(.trailing, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private func boardColumns(_ family: FamilySnapshot) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls(family)
                    if family.choreDoers.isEmpty {
                        EmptyCard(symbol: "person.badge.plus", title: "No one has chores yet", message: "Add kids in Household, then give out chores.")
                    }
                    let kids = family.choreDoers.filter { kidFilter == nil || $0.id == kidFilter }
                    // Even columns while an iPhone Duo is partly folded (DuoGrid.swift).
                    DuoAdaptiveGrid(minimum: 250, spacing: 12, alignment: .leading, itemAlignment: .top) {
                        ForEach(kids) { kid in
                            let items = family.items(for: kid).filter { !$0.chore.upForGrabs || $0.memberID == kid.id }
                            KidColumn(kid: kid, items: items, family: family, onEdit: edit, onToggle: toggle)
                        }
                    }
                    let grabs = family.items().filter { $0.chore.upForGrabs && $0.memberID == nil }
                    ForEach(grabs) { item in
                        UpForGrabsRow(item: item, family: family, onEdit: edit) { kid in
                            Family.markDone(item, by: kid.id, byParent: true, in: context)
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
    }
}

/// A kid's chores for today on iPhone: their name and progress, then the rows.
private struct KidChoreSection: View {
    var kid: Member
    var items: [BoardItem]
    var family: FamilySnapshot
    var onEdit: (UUID) -> Void
    var onToggle: (BoardItem, Member) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Whose chores these are, at a glance.
                MemberAvatar(kid, size: 28)
                Text(kid.name).font(.title3.bold())
                Spacer()
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if items.isEmpty {
                Card { Text("Nothing today.").foregroundStyle(.secondary) }
            } else {
                CardList(items: items, inset: 56) { item in
                    ChoreRow(item: item, color: kid.color.color, onEdit: onEdit) { onToggle(item, kid) }
                }
            }
        }
    }

    private var summary: String {
        let done = items.filter { $0.status.isDone }.count
        let earned = items.filter { $0.status == .approved }.reduce(0) { $0 + $1.points }
        // Parents' chores don't earn points.
        guard kid.isKid else { return "\(done) of \(items.count) done" }
        return "\(done) of \(items.count) done · \(PointWords.current().count(earned)) earned"
    }
}

/// A kid's column on iPad: avatar, progress bar, then the rows.
private struct KidColumn: View {
    var kid: Member
    var items: [BoardItem]
    var family: FamilySnapshot
    var onEdit: (UUID) -> Void
    var onToggle: (BoardItem, Member) -> Void

    var body: some View {
        let done = items.filter { $0.status.isDone }.count
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MemberAvatar(kid, size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kid.name).font(.headline)
                        Text("\(done) of \(items.count) done")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    if kid.isKid {
                        PointsLabel(points: family.balance(of: kid), font: .footnote.weight(.semibold))
                    }
                }
                ProgressView(value: items.isEmpty ? 0 : Double(done) / Double(items.count))
                    .tint(kid.color.color)
                    .animation(.spring(duration: 0.5, bounce: 0.4), value: done)
            }
            .padding(14)
            ForEach(items) { item in
                Divider()
                ChoreRow(item: item, color: kid.color.color, onEdit: onEdit) { onToggle(item, kid) }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

/// One chore on the board: the check (a parent's tap approves), the name, how often, a tag
/// when it's waiting or wants a photo, and the points. Tapping the name edits the chore;
/// a long press opens the complete / edit / delete menu.
struct ChoreRow: View {
    var item: BoardItem
    var color: Color
    /// Nil where the editor can't open: tapping the name does nothing and the menu has no Edit.
    var onEdit: ((UUID) -> Void)?
    var onToggle: () -> Void

    @Query private var rooms: [Room]

    private var room: Room? {
        guard let id = item.chore.roomID else { return nil }
        return rooms.first { $0.id == id && !$0.isArchived }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                ChoreCheck(status: item.status, color: color)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checkLabel)
            .sensoryFeedback(.success, trigger: item.status == .approved)

            Button {
                onEdit?(item.chore.id)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.chore.title)
                            .strikethrough(item.status == .approved)
                            .foregroundStyle(item.status == .approved ? .secondary : .primary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if item.chore.priority != .unset {
                                PriorityMarks(priority: item.chore.priority)
                            }
                            if let room {
                                RoomLabel(room: room)
                                    .foregroundStyle(Color.secondary)
                                Text("·").font(.caption).foregroundStyle(Color(.tertiaryLabel))
                            }
                            Text(item.chore.repeatRule.label)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                            if item.status == .pending {
                                TagLabel(text: "Waiting for OK", color: Brand.waiting)
                            } else if item.wasSentBack {
                                TagLabel(text: "Sent back", color: Brand.waiting)
                            } else if item.chore.requiresPhoto {
                                TagLabel(text: "Photo", color: .secondary)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    PointsLabel(points: item.points, font: .footnote.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(onEdit == nil ? "" : "Edit chore")
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(minHeight: 60)
        .choreActions(title: item.chore.title, choreID: item.chore.id, onEdit: onEdit) {
            Button(completeTitle, menuIcon: completeSymbol, action: onToggle)
        }
    }

    /// The menu's first action follows the check: complete, approve, or take it back.
    private var completeTitle: String {
        switch item.status {
        case .open: "Mark Complete"
        case .pending: "Approve"
        case .approved: "Mark Not Done"
        }
    }

    private var completeSymbol: String {
        switch item.status {
        case .open: "checkmark.circle"
        case .pending: "checkmark.seal"
        case .approved: "arrow.uturn.backward.circle"
        }
    }

    private var checkLabel: String {
        switch item.status {
        case .open: "Mark \(item.chore.title) done"
        case .pending: "Approve \(item.chore.title)"
        case .approved: "Undo \(item.chore.title)"
        }
    }
}

/// An unclaimed up-for-grabs chore. The check asks which kid did it.
private struct UpForGrabsRow: View {
    var item: BoardItem
    var family: FamilySnapshot
    var onEdit: (UUID) -> Void
    var onDone: (Member) -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Section("Who did it?") {
                    ForEach(eligible) { kid in
                        Button(kid.name) { onDone(kid) }
                    }
                }
            } label: {
                ChoreCheck(status: .open, color: accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Mark \(item.chore.title) done")
            Button {
                onEdit(item.chore.id)
            } label: {
                HStack {
                    IconTile(symbol: item.chore.symbol, color: accent, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.chore.title)
                        Text("First to claim it gets the \(PointWords.current().plural)")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    PointsLabel(points: item.points, font: .footnote.weight(.semibold))
                    TagLabel(text: "Unclaimed", color: .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(minHeight: 64)
        .choreActions(title: item.chore.title, choreID: item.chore.id, onEdit: onEdit) {
            // Up for grabs: completing it means saying who did it.
            Menu("Mark Complete", menuIcon: "checkmark.circle") {
                Section("Who did it?") {
                    ForEach(eligible) { kid in
                        Button(kid.name) { onDone(kid) }
                    }
                }
            }
        }
    }

    private var eligible: [Member] {
        item.chore.assigneeIDs.isEmpty ? family.kids : family.members.filter { item.chore.assigneeIDs.contains($0.id) }
    }
}

/// This week: every chore for each kid, with a dot for each day it comes up.
private struct WeekBoard: View {
    var family: FamilySnapshot
    var kidFilter: UUID?
    var onEdit: (UUID) -> Void

    private var days: [Date] {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? calendar.startOfDay(for: .now)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        let days = days
        let kids = family.choreDoers.filter { kidFilter == nil || $0.id == kidFilter }
        ForEach(kids) { kid in
            let perDay = days.map { family.items(for: kid, on: $0).filter { !$0.chore.upForGrabs || $0.memberID == kid.id } }
            let chores = uniqueChores(perDay.flatMap { $0 })
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(kid.color.color).frame(width: 10, height: 10)
                    Text(kid.name).font(.title3.bold())
                    Spacer()
                    if kid.isKid {
                        Text("\(PointWords.current().count(family.earnedThisWeek(by: kid))) this week")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer()
                        ForEach(days, id: \.self) { day in
                            Text(day.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Calendar.current.isDateInToday(day) ? kid.color.color : .secondary)
                                .frame(width: 26)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    ForEach(chores, id: \.id) { chore in
                        Button {
                            onEdit(chore.id)
                        } label: {
                            HStack(spacing: 0) {
                                Text(chore.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                ForEach(Array(days.enumerated()), id: \.offset) { index, _ in
                                    let item = perDay[index].first { $0.chore.id == chore.id }
                                    dot(item, color: kid.color.color)
                                        .frame(width: 26)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 14)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            }
        }
    }

    @ViewBuilder
    private func dot(_ item: BoardItem?, color: Color) -> some View {
        if let item {
            Circle()
                .fill(item.status == .open ? Color.clear : (item.status == .pending ? Brand.waiting : color))
                .overlay(Circle().strokeBorder(item.status == .open ? Color(.systemGray3) : Color.clear, lineWidth: 1.5))
                .frame(width: 12, height: 12)
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    private func uniqueChores(_ items: [BoardItem]) -> [ChoreRecord] {
        var seen = Set<UUID>()
        return items.compactMap { item in
            seen.insert(item.chore.id).inserted ? item.chore : nil
        }
    }
}

#Preview {
    NavigationStack { ChoresView() }
        .previewEnvironment()
}

/// Reminders-style priority marks in the chore list: ! low, !! medium, !!! high.
struct PriorityMarks: View {
    var priority: ChorePriority

    var body: some View {
        Text(priority.marks)
            .font(.caption.weight(.heavy))
            .foregroundStyle(color)
            .accessibilityLabel("\(priority.label) priority")
    }

    private var color: Color {
        switch priority {
        case .unset, .low: .secondary
        case .medium: Brand.waiting
        case .high: .red
        }
    }
}
