import SwiftData
import SwiftUI

/// The parent's chore board. iPhone: a card per kid. iPad: a column per kid, with Needs Your OK
/// alongside.
struct ChoresView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query private var points: [PointEntry]
    @Query private var redemptions: [Redemption]

    @State private var range: BoardRange = .today
    @State private var kidFilter: UUID?
    @State private var editing: Chore?

    enum BoardRange: String, CaseIterable, Identifiable {
        case today = "Today", week = "This Week"
        var id: String { rawValue }
    }

    private var family: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: points, redemptions: redemptions)
    }

    var body: some View {
        let family = family
        Group {
            if sizeClass == .regular && range == .today {
                wideBoard(family)
            } else {
                CalomaScreen(title: "Chores") {
                    controls(family)
                    if family.kids.isEmpty {
                        EmptyCard(symbol: "person.badge.plus", title: "No kids yet", message: "Add kids in Family, then give them chores.")
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
                Button {
                    router.openKidView()
                } label: {
                    Label("Kid View", systemImage: "figure.and.child.holdinghands")
                }
                Button {
                    router.sheet = .approvals
                } label: {
                    Label("Needs Your OK", systemImage: "checkmark.shield")
                }
                .badge(family.needsOKCount)
                Button {
                    router.sheet = .newChore
                } label: {
                    Label("New Chore", systemImage: "plus")
                }
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
        Picker("Range", selection: $range) {
            ForEach(BoardRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)

        if family.kids.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Chip(title: "Everyone", color: accent, isOn: kidFilter == nil, showsDot: false) { kidFilter = nil }
                    ForEach(family.kids) { kid in
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
        let kids = family.kids.filter { kidFilter == nil || $0.id == kidFilter }
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

    private func wideBoard(_ family: FamilySnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls(family)
                    if family.kids.isEmpty {
                        EmptyCard(symbol: "person.badge.plus", title: "No kids yet", message: "Add kids in Family, then give them chores.")
                    }
                    let kids = family.kids.filter { kidFilter == nil || $0.id == kidFilter }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
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
                Circle().fill(kid.color.color).frame(width: 10, height: 10)
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
                    PointsLabel(points: family.balance(of: kid), font: .footnote.weight(.semibold))
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
/// when it's waiting or wants a photo, and the points. Tapping the name edits the chore.
struct ChoreRow: View {
    var item: BoardItem
    var color: Color
    var onEdit: (UUID) -> Void
    var onToggle: () -> Void

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
                onEdit(item.chore.id)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.chore.title)
                            .strikethrough(item.status == .approved)
                            .foregroundStyle(item.status == .approved ? .secondary : .primary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(item.chore.repeatRule.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit chore")
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(minHeight: 60)
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
        let eligible = family.kids.filter { item.chore.assigneeIDs.isEmpty || item.chore.assigneeIDs.contains($0.id) }
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
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    PointsLabel(points: item.points, font: .footnote.weight(.semibold))
                    TagLabel(text: "Unclaimed", color: accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(minHeight: 64)
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
        let kids = family.kids.filter { kidFilter == nil || $0.id == kidFilter }
        ForEach(kids) { kid in
            let perDay = days.map { family.items(for: kid, on: $0).filter { !$0.chore.upForGrabs || $0.memberID == kid.id } }
            let chores = uniqueChores(perDay.flatMap { $0 })
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(kid.color.color).frame(width: 10, height: 10)
                    Text(kid.name).font(.title3.bold())
                    Spacer()
                    Text("\(PointWords.current().count(family.earnedThisWeek(by: kid))) this week")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
