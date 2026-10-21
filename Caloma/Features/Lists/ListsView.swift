import SwiftData
import SwiftUI

/// Lists: what's on now, each person's progress, and the lists the family has used before to
/// start the next one from.
struct ListsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \FamilyList.createdAt, order: .reverse) private var lists: [FamilyList]
    @Query private var items: [FamilyListItem]
    @Query private var checks: [FamilyListCheck]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @State private var editing: ListEditorTarget?
    @State private var finishing: FamilyList?

    private var family: [Member] { members.filter { !$0.isArchived } }

    var body: some View {
        let active = FamilyLists.active(lists)
        let reusable = Array(FamilyLists.reusable(lists).prefix(8))
        CalomaScreen(title: "Lists") {
            if active.isEmpty {
                EmptyCard(symbol: "checklist", title: "No lists right now", message: "Make one for a trip, a party or anything coming up. Everyone sees their part on their own screen.")
            } else {
                ForEach(active) { list in
                    ListProgressCard(list: list, items: items, checks: checks, members: family) {
                        editing = .edit(list)
                    } onFinish: {
                        finishing = list
                    }
                }
            }

            if !reusable.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Start from a List You've Used")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                        ForEach(reusable) { old in
                            Button {
                                editing = .reuse(old)
                            } label: {
                                ReusableListTile(list: old, count: FamilyLists.items(of: old, in: items).count)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("A finished list tucks itself away and comes back here as a starting point next time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Group {
                    Button {
                        editing = .new
                    } label: {
                        Label("New List", systemImage: "plus")
                    }
                }
                // White over the color header.
                .tint(.white)
            }
        }
        .sheet(item: $editing) { target in
            ListEditor(target: target)
                .tint(accent)
        }
        .alert(finishing.map { "Finish \($0.title)?" } ?? "", isPresented: Binding(get: { finishing != nil }, set: { if !$0 { finishing = nil } })) {
            Button("Finish List") {
                if let finishing { withAnimation { FamilyLists.finish(finishing, in: context) } }
                finishing = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It comes off everyone's screens and waits here to use again.")
        }
        .task { FamilyLists.clearFinished(in: context) }
    }
}

/// Which list the editor is for.
enum ListEditorTarget: Identifiable {
    case new
    case edit(FamilyList)
    /// A new list with the same things as a finished one.
    case reuse(FamilyList)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let list): list.id.uuidString
        case .reuse(let list): "reuse-" + list.id.uuidString
        }
    }
}

/// One list now: its name, when it's needed, the family's progress, and a row per person that
/// opens to show their things.
struct ListProgressCard: View {
    var list: FamilyList
    var items: [FamilyListItem]
    var checks: [FamilyListCheck]
    var members: [Member]
    var onEdit: () -> Void
    var onFinish: () -> Void

    @Environment(\.accent) private var accent
    @Environment(\.modelContext) private var context
    @State private var open: UUID?

    private var people: [Member] {
        members.filter { !FamilyLists.items(of: list, for: $0.id, in: items).isEmpty }
    }

    var body: some View {
        let overall = FamilyLists.progress(of: list, in: items, checks: checks, members: members)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    IconTile(symbol: list.symbol, color: accent, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(list.title.isEmpty ? "Untitled List" : list.title)
                            .font(.title3.weight(.bold))
                        Text(ListText.when(list))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Menu {
                        Button("Edit List", menuIcon: "pencil", action: onEdit)
                        Button("Finish List", menuIcon: "checkmark.circle", action: onFinish)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .tint(.primary)
                    .accessibilityLabel("List options")
                }
                ProgressBar(value: overall.total == 0 ? 0 : Double(overall.done) / Double(overall.total), color: overall.done == overall.total && overall.total > 0 ? Brand.done : accent)
                    .frame(height: 8)
                    .accessibilityLabel("\(overall.done) of \(overall.total) done")
            }
            .padding(16)

            if people.isEmpty {
                Button(action: onEdit) {
                    Label("Add things to the list", systemImage: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                .tint(.primary)
                .overlay(alignment: .top) { Divider() }
            }

            ForEach(people) { person in
                personRow(person)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .contentShape(.rect(cornerRadius: 24))
        .contextMenu {
            Button("Edit List", menuIcon: "pencil", action: onEdit)
            Button("Finish List", menuIcon: "checkmark.circle", action: onFinish)
        }
    }

    private func personRow(_ person: Member) -> some View {
        let mine = FamilyLists.items(of: list, for: person.id, in: items)
        let done = mine.filter { FamilyLists.isDone($0, for: person.id, checks: checks) }.count
        let isOpen = open == person.id
        let all = done == mine.count
        return VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.leading, 64)
            Button {
                withAnimation(.snappy) { open = isOpen ? nil : person.id }
            } label: {
                HStack(spacing: 12) {
                    MemberAvatar(person, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.name)
                            .font(.body.weight(.semibold))
                        Text(all ? "All done" : (done == 0 ? "Not started · \(mine.count) \(mine.count == 1 ? "thing" : "things")" : "\(done) of \(mine.count) done"))
                            .font(.footnote.weight(all ? .semibold : .regular))
                            .foregroundStyle(all ? Brand.done : .secondary)
                    }
                    Spacer(minLength: 6)
                    ProgressBar(value: mine.isEmpty ? 0 : Double(done) / Double(mine.count), color: all ? Brand.done : person.color.color)
                        .frame(width: 72, height: 6)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 58)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides their things" : "Shows their things")

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(mine) { item in
                        let checked = FamilyLists.isDone(item, for: person.id, checks: checks)
                        // A parent can check off anyone's things, for that person only.
                        Button {
                            withAnimation(.snappy) { FamilyLists.toggle(item, for: person.id, in: context) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(checked ? Brand.done : Color(.systemGray3))
                                    .contentTransition(.symbolEffect(.replace))
                                Text(item.title)
                                    .strikethrough(checked)
                                    .foregroundStyle(checked ? .secondary : .primary)
                                Spacer(minLength: 4)
                                if item.everyone {
                                    Text("Everyone")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                            .font(.subheadline)
                            .frame(minHeight: 36)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .sensoryFeedback(.selection, trigger: checked)
                        .accessibilityLabel("\(item.title), \(person.name)")
                        .accessibilityValue(checked ? "Done" : "Not done")
                        .accessibilityHint(checked ? "Un-checks it for \(person.name)" : "Checks it off for \(person.name)")
                    }
                }
                .padding(.leading, 60)
                .padding(.trailing, 16)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// A finished list, to start the next one from.
private struct ReusableListTile: View {
    var list: FamilyList
    var count: Int
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: list.symbol, color: accent, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.title.isEmpty ? "Untitled List" : list.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        .contentShape(.rect(cornerRadius: 18))
        .accessibilityHint("Starts a new list with the same things")
    }

    private var detail: String {
        var parts = ["\(count) \(count == 1 ? "thing" : "things")"]
        if let used = list.archivedAt ?? list.endsAt {
            parts.append("last used " + used.formatted(.dateTime.month(.wide)))
        }
        return parts.joined(separator: " · ")
    }
}

/// A thin rounded bar, filled to `value` (0…1).
struct ProgressBar: View {
    var value: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * proxy.size.width)
            }
        }
        .animation(.smooth, value: value)
    }
}

/// Words lists use in more than one place.
enum ListText {
    /// "Needed by Fri 5:00 PM · in 2 days", "For Bear Lake weekend", or "No date".
    static func when(_ list: FamilyList, now: Date = .now) -> String {
        guard let due = list.dueAt else {
            return list.eventID == nil ? "No date" : "For an event on the calendar"
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        let time = due.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        switch days {
        case ..<0: return "Was needed by \(time)"
        case 0: return "Needed by today, \(due.formatted(date: .omitted, time: .shortened))"
        case 1: return "Needed by tomorrow, \(due.formatted(date: .omitted, time: .shortened))"
        default: return "Needed by \(time) · in \(days) days"
        }
    }

    /// For a kid: "By Friday", "By tonight".
    static func kidWhen(_ list: FamilyList, now: Date = .now) -> String? {
        guard let due = list.dueAt else { return nil }
        let calendar = Calendar.current
        if calendar.isDate(due, inSameDayAs: now) { return "By today" }
        if calendar.isDateInTomorrow(due) { return "By tomorrow" }
        return "By " + due.formatted(.dateTime.weekday(.wide))
    }
}

// MARK: - Home

/// Home's Lists section: the lists on now, or a nudge to make one.
struct ListsHomeCard: View {
    @Query(sort: \FamilyList.createdAt, order: .reverse) private var lists: [FamilyList]
    @Query private var items: [FamilyListItem]
    @Query private var checks: [FamilyListCheck]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Environment(\.accent) private var accent

    var body: some View {
        let active = FamilyLists.active(lists)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Lists") {
                NavigationLink("See All") { ListsView() }
            }
            if active.isEmpty {
                NavigationLink {
                    ListsView()
                } label: {
                    HStack(spacing: 14) {
                        IconTile(symbol: "checklist", color: accent, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Packing for a trip?")
                                .font(.headline)
                            Text("Make a list and give everyone their part.")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                }
                .buttonStyle(.plain)
            } else {
                ForEach(active.prefix(3)) { list in
                    let progress = FamilyLists.progress(of: list, in: items, checks: checks, members: members.filter { !$0.isArchived })
                    NavigationLink {
                        ListsView()
                    } label: {
                        HStack(spacing: 14) {
                            IconTile(symbol: list.symbol, color: accent, size: 44)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(list.title.isEmpty ? "Untitled List" : list.title)
                                        .font(.headline)
                                    Spacer()
                                    Text("\(progress.done)/\(progress.total)")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(Color.secondary)
                                }
                                ProgressBar(value: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), color: progress.done == progress.total && progress.total > 0 ? Brand.done : accent)
                                    .frame(height: 6)
                                Text(ListText.when(list))
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

extension Brand {
    /// Done, on lists: the same green as approved chores.
    nonisolated static let done = Color(hex: 0x1E9E6A)
}
